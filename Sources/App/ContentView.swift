// ContentView — sidebar shell + content router.
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var M: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    struct Tab { let id, label, icon: String }

    // 侧栏图标约定：一律 outline（非 .fill），相近笔画密度；渲染见 sidebarIcon。
    // 分组遵循原型：概览 / 代理 / 网络 / 配置。
    private let overviewTabs: [Tab] = [
        .init(id: "dashboard", label: "仪表盘", icon: "gauge.with.dots.needle.67percent"),
    ]
    // 代理：节点、分流规则、实时连接
    private let proxyTabs: [Tab] = [
        .init(id: "proxies",     label: "代理",   icon: "diamond"),
        .init(id: "rules",       label: "规则",   icon: "list.bullet.rectangle"),
        .init(id: "connections", label: "连接",   icon: "link"),
    ]
    // 网络：SD-WAN 共存、入站/TUN/DNS/嗅探、日志
    private let networkTabs: [Tab] = [
        .init(id: "map",     label: "SD-WAN", icon: "point.3.connected.trianglepath.dotted"),
        .init(id: "network", label: "网络",    icon: "network"),
        .init(id: "logs",    label: "日志",    icon: "text.alignleft"),
    ]
    // 配置：订阅、profile 编辑、偏好
    private let configTabs: [Tab] = [
        .init(id: "subscriptions", label: "节点",   icon: "icloud.and.arrow.down"),
        .init(id: "config",        label: "配置编辑", icon: "slider.horizontal.3"),
        .init(id: "general",       label: "设置",   icon: "gearshape"),
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
                    statusCard
                        .padding(.top, DS.Spacing.m)
                        .padding(.bottom, DS.Spacing.xs)

                    sidebarSection("概览", tabs: overviewTabs, first: true)
                    sidebarSection("代理", tabs: proxyTabs)
                    sidebarSection("网络", tabs: networkTabs)
                    sidebarSection("配置", tabs: configTabs)
                }
                .padding(.horizontal, DS.Spacing.s + 2)
                .padding(.bottom, DS.Spacing.s)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider().overlay(DS.Palette.separator)
            statusFooter
        }
        .background(DS.Palette.sidebarBg)
    }

    /// 侧栏状态卡 — 原型 `.sb-status`：运行状态 + 模式徽章 / 当前出口 / 速率 + 连接数。
    private var statusCard: some View {
        let running = M.reachable
        let connecting = M.engine.isBusy && !M.reachable
        let dot = running ? DS.Palette.ok : (connecting ? DS.Palette.warn : DS.Palette.error)
        let state = running ? "代理运行中" : (connecting ? "连接中…" : "未连接")

        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 7) {
                DSDot(color: dot)
                Text(state)
                    .font(.dsCaption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: DS.Spacing.xs)
                DSKindBadge(text: modeLabel(M.mode))
            }

            Text(currentOutbound)
                .font(.dsSidebarName)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: 7) {
                DSDot(color: DS.Palette.accent, size: 5)
                Text(fmtRate(Double(M.curDown)))
                    .font(.dsMonoSm)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Spacer(minLength: DS.Spacing.xs)
                Text("\(M.activeConnectionsCount) 连接")
                    .font(.dsMonoSm)
                    .monospacedDigit()
                    .foregroundStyle(DS.Palette.textFaint)
            }
            .padding(.top, 1)
        }
        .padding(.horizontal, DS.Spacing.s + 2)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .dsCardChrome(radius: 9)
    }

    /// 当前生效出口：优先第一个 selector 组的选中项，回落到模式名。
    private var currentOutbound: String {
        if let g = M.groups.first(where: { $0.type.lowercased() == "selector" }), !g.now.isEmpty {
            return g.now
        }
        if let g = M.groups.first, !g.now.isEmpty { return g.now }
        return modeLabel(M.mode)
    }

    @ViewBuilder
    private func sidebarSection(_ title: String, tabs: [Tab], first: Bool = false) -> some View {
        Text(title)
            .font(.dsSectionLabel)
            .foregroundStyle(DS.Palette.textFaint)
            .textCase(nil)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, first ? DS.Spacing.m : DS.Spacing.l + DS.Spacing.xs)
            .padding(.bottom, DS.Spacing.s)
            .padding(.leading, DS.Spacing.s + 1)

        VStack(alignment: .leading, spacing: DS.Layout.sidebarRowGap) {
            ForEach(tabs, id: \.id) { t in
                sidebarNavRow(t)
            }
        }
    }

    /// 导航行 — 原型 `.sb-item`：30pt 高、radius 7、9pt 图文间距；
    /// 选中填 accent、文字/图标走 accentInk；右侧可挂 mono 计数徽章。
    private func sidebarNavRow(_ t: Tab) -> some View {
        let selected = M.route == t.id
        return Button {
            M.route = t.id
        } label: {
            HStack(spacing: 9) {
                sidebarIcon(t.icon)
                    .foregroundStyle(selected ? DS.Palette.accentInk : Color.secondary)
                Text(t.label)
                    .font(selected ? .dsBodySemibold : .dsBody)
                    .foregroundStyle(selected ? DS.Palette.accentInk : Color.primary)
                    .lineLimit(1)
                Spacer(minLength: DS.Spacing.xs)
                if let badge = navBadge(t.id) {
                    Text(badge)
                        .font(.dsMonoTiny)
                        .monospacedDigit()
                        .foregroundStyle(selected ? DS.Palette.accentInk.opacity(0.8) : DS.Palette.textFaint)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: DS.Layout.sidebarRowHeight)
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

    /// 行尾计数徽章 — 仅活跃连接数（其余页面无稳定计数语义）。
    private func navBadge(_ id: String) -> String? {
        guard id == "connections", M.activeConnectionsCount > 0 else { return nil }
        return "\(M.activeConnectionsCount)"
    }

    /// 侧栏导航图标：统一 outline 字形、字重、渲染模式与占位框，避免 fill/line 混用导致视觉轻重不一。
    private func sidebarIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(DS.Icon.font(DS.Icon.sm, weight: .medium))
            .symbolRenderingMode(.monochrome)
            .frame(width: DS.Icon.md, height: DS.Icon.md, alignment: .center)
            .contentShape(Rectangle())
    }

    /// 品牌行 — 原型 `.sb-brand`：24pt accent 渐变 logo + 14/700 名称 + 版本副标。
    /// 高度与内容区 PageToolbar 同为 chromeHeight，底部分割线通栏对齐。
    /// 副标只放 App 版本 + build；内核版本在侧栏底部 footer，不在这里重复。
    private var appHeader: some View {
        HStack(spacing: DS.Spacing.s) {
            Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                .resizable()
                .interpolation(.high)
                .frame(width: 24, height: 24)
                .clipShape(DS.Shape.control())

            VStack(alignment: .leading, spacing: 1) {
                Text("ClashHalo")
                    .font(.dsAppName)
                    .tracking(-0.2)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(verbatim: "v\(Self.appVersion) · build \(Self.appBuild)")
                    .font(.dsMonoMicro)
                    .foregroundStyle(DS.Palette.textFaint)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        // 水平 inset 与状态卡/导航行同源，跨栏视觉网格一致
        .padding(.horizontal, DS.Spacing.s + 6)
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
                    HStack(spacing: 9) {
                        Image(systemName: "exclamationmark.shield.fill")
                            .font(DS.Icon.font(DS.Icon.sm, weight: .medium))
                            .foregroundStyle(DS.Palette.warn)
                            .frame(width: DS.Icon.md, height: DS.Icon.md)
                        Text("特权服务待更新")
                            .font(.dsBody)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.dsCaption).foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 9)
                    .frame(height: DS.Layout.sidebarRowHeight)
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
            HStack(spacing: 9) {
                let connecting = M.engine.isBusy && !M.reachable
                Circle()
                    .fill(M.reachable ? DS.Palette.ok : (connecting ? DS.Palette.warn : DS.Palette.error))
                    .frame(width: 6, height: 6)
                    .frame(width: DS.Icon.md, height: DS.Icon.md, alignment: .center)
                Text("内核")
                    .font(.dsBody)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(M.reachable ? (M.version.isEmpty || M.version == "?" ? "—" : M.version)
                                 : (connecting ? "连接中…" : "未连接"))
                    .font(M.reachable ? .dsMonoSm : .dsBody)
                    .foregroundStyle(M.reachable ? .primary : .secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .padding(.horizontal, 9)
            .frame(height: DS.Layout.sidebarRowHeight - 4)
        }
        .padding(.horizontal, DS.Spacing.s + 2)
        .padding(.top, DS.Spacing.s)
        .padding(.bottom, DS.Spacing.m)
        .background(DS.Palette.sidebarBg)
    }

    private func statusToggle(_ label: String, icon: String, isOn: Binding<Bool>, onColor: Color) -> some View {
        let busy = M.engine.isBusy
        return HStack(spacing: 9) {
            // 与导航行共用 sm 字号 + monochrome + md 槽
            Image(systemName: icon)
                .font(DS.Icon.font(DS.Icon.sm, weight: .medium))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(isOn.wrappedValue ? onColor : .secondary)
                .frame(width: DS.Icon.md, height: DS.Icon.md, alignment: .center)
            Text(label)
                .font(.dsBody)
                .foregroundStyle(busy ? .secondary : (isOn.wrappedValue ? .primary : .secondary))
                .lineLimit(1)
            Spacer(minLength: 0)
            if busy {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(DS.Progress.miniScale)
            }
            // 走 DSSwitch —— 侧栏开关此前是 .mini，比设置页里的同类开关小一号。
            // busy 时禁用，避免连点只靠 toast 解释（design.md §10.1）
            DSSwitch(isOn: isOn, tint: onColor, disabled: busy)
        }
        .padding(.horizontal, 9)
        .frame(height: DS.Layout.sidebarRowHeight)
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

/// Page top bar — 标题 + 右侧动作。标题可为空（只留动作）。
///
/// 动作区锁死 `controlHeight`：按钮 / 分段控件 / 菜单选择器的固有高度算法不同
/// （Seg 的等分段会把自身撑高），不锁则同一排控件高度参差。
struct PageHead<Actions: View>: View {
    let title: String
    @ViewBuilder var actions: () -> Actions

    private var hasTitle: Bool { !title.isEmpty }
    private var hasActions: Bool { Actions.self != EmptyView.self }

    var body: some View {
        if hasTitle || hasActions {
            HStack(alignment: .center, spacing: DS.Spacing.m) {
                if hasTitle {
                    Text(title)
                        .font(.dsPageTitle)
                        .tracking(-0.4)
                        .foregroundColor(.primary)
                        .fixedSize()
                }
                Spacer(minLength: 0)

                if hasActions {
                    HStack(spacing: DS.Spacing.s) {
                        actions()
                    }
                    // 按最高的控件（Seg = segHeight）定高，按钮在其中垂直居中。
                    // 用 controlHeight 会把 Seg 压掉 2pt。
                    .frame(height: DS.Layout.segHeight)
                }
            }
            // 这一行必须不看 hasActions 就锁死同一个高度：之前只在有 actions 时
            // 给内层套 segHeight，没有 actions 的页面这一行只有标题文字自己的行高
            // （~25pt），比 segHeight（34pt）矮一截——切换到没有 actions 的页面时
            // 标题栏就会跟着变矮，来回切页标题会明显上下跳动。
            .frame(minHeight: DS.Layout.segHeight)
            .padding(.horizontal, DS.Layout.pageContentInset)
            .padding(.top, hasTitle ? DS.Spacing.l : DS.Spacing.m)
            .padding(.bottom, 14)
        }
    }
}

extension PageHead where Actions == EmptyView {
    init(title: String) {
        self.init(title: title, actions: { EmptyView() })
    }
}

// MARK: - Reusable card container

struct Card<Content: View, Actions: View>: View {
    var title: String?
    var icon: String?
    var pad: Bool
    /// 定高。同一栅格行里的卡片必须传同一个值，否则各自按内容高度渲染就会高矮不齐。
    /// 传 `nil` 保持内容自适应（`.frame(height: nil)` 是空操作）。
    var height: CGFloat?
    /// 撑满所在栅格行的高度。表单卡内容高度由行数决定、事先算不出来，
    /// 用它让同一 `GridRow` 里的卡片对齐到最高那张，而不是各自参差。
    /// 只在栅格行内使用 —— 直接放进 ScrollView 的 VStack 会吃掉剩余高度。
    var stretch: Bool = false
    @ViewBuilder var actions: () -> Actions
    @ViewBuilder var content: () -> Content

    init(title: String? = nil, icon: String? = nil, pad: Bool = true, height: CGFloat? = nil,
         stretch: Bool = false,
         @ViewBuilder actions: @escaping () -> Actions, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.icon = icon
        self.pad = pad
        self.height = height
        self.stretch = stretch
        self.actions = actions
        self.content = content
    }

    /// 卡头遵循原型 `.card-head`：uppercase 11/700 灰标题 + 0.5px 底分隔 + 极淡底色。
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let title {
                HStack(spacing: DS.Spacing.s) {
                    if let icon {
                        Image(systemName: icon)
                            .font(DS.Icon.font(12, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                    Text(title)
                        .font(.dsCardTitle)
                        .tracking(0.4)
                        .textCase(.uppercase)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        // 卡头标题不参与压缩：窄卡片下先挤 actions，不把标题折行
                        .fixedSize()
                    Spacer(minLength: DS.Spacing.xs)
                    actions()
                }
                .padding(.horizontal, DS.Spacing.m)
                .frame(height: DS.Layout.cardHeadHeight)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DS.Palette.cardHeadBg)
                .overlay(alignment: .bottom) {
                    Rectangle().fill(DS.Palette.border).frame(height: 0.5)
                }
            }
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, pad ? DS.Spacing.m : 0)
                .padding(.bottom, pad ? DS.Spacing.m : 0)
                .padding(.top, pad ? DS.Spacing.m : 0)
            Spacer(minLength: 0)
        }
        // 高度必须在这里锁定，而不是由调用点在外面套 `.frame(height:)`：
        // chrome（背景 + 边框）画在这一层，外层 frame 只会把已按内容高度画好的
        // 卡片居中放进槽里 —— 于是同行卡片高矮不齐、左右列还上下错位。
        //
        // 不用 `maxHeight: .infinity`：那会让卡片吃掉 ScrollView 的剩余高度并
        // 按兄弟数量瓜分，同样导致高度不一致。
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: height, alignment: .top)
        .frame(maxHeight: stretch ? .infinity : nil, alignment: .top)
        .clipped()
        .dsCardChrome()
    }
}

extension Card where Actions == EmptyView {
    init(title: String? = nil, icon: String? = nil, pad: Bool = true, height: CGFloat? = nil,
         stretch: Bool = false, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, icon: icon, pad: pad, height: height, stretch: stretch,
                  actions: { EmptyView() }, content: content)
    }
}
