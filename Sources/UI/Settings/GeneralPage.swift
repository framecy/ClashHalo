import SwiftUI

// MARK: - Settings

struct GeneralPage: View {
    @EnvironmentObject var M: AppModel
    @ObservedObject private var engine = EngineControl.shared
    @State private var host = ""
    @State private var port = ""
    @State private var secret = ""
    @State private var selectedTab = "general" // "general", "advanced", "privilege", "about"
    @State private var helperBusy = false

    var body: some View {
        VStack(spacing: 0) {
            // 顶栏与侧栏 appHeader / PageToolbar 同高：m + 32 + m，分割线通栏对齐
            DSSegmentedControl(selection: $selectedTab, choices: [
                DSChoice("通用", "general", systemImage: "gearshape"),
                DSChoice("高级设置", "advanced", systemImage: "slider.horizontal.3"),
                DSChoice("权限", "privilege", systemImage: "shield"),
                DSChoice("关于", "about", systemImage: "info.circle")
            ])
            .padding(.horizontal, DS.Layout.pageContentInset)
            .padding(.vertical, DS.Spacing.m)
            .frame(height: DS.Layout.chromeHeight, alignment: .center)
            .frame(maxWidth: .infinity)
            .background(DS.Palette.chromeBg)

            Divider().overlay(DS.Palette.separator)

            ScrollView {
                VStack(spacing: DS.Spacing.m) {
                    if selectedTab == "general" {
                        // 菜单栏
                        Card(title: "菜单栏", icon: "menubar.rectangle") {
                            HStack {
                                Text("显示策略组选择").font(.dsBody)
                                Spacer()
                                Toggle("", isOn: Binding(get: { M.menuBarGroups }, set: { M.menuBarGroups = $0 }))
                                    .toggleStyle(.switch).labelsHidden()
                                    .frame(width: DS.Layout.fieldTrailing, alignment: .trailing)
                            }
                            Text("开启后菜单栏面板内可逐组切换节点；策略组较多时可关闭以保持面板紧凑，节点切换仍可在「策略」页操作。")
                                .font(.dsBody).foregroundColor(.secondary).padding(.top, DS.Spacing.s)
                        }

                        // GEO 数据库
                        Card(title: "GEO 数据库", icon: "globe.asia.australia") {
                            VStack(spacing: 2) {
                                ToggleRow("DAT 模式", key: "geodata-mode", persistent: true)
                                PickerRow("加载器", key: "geodata-loader", options: [("memconservative","内存优先"),("standard","标准")], persistent: true)
                                ToggleRow("自动更新", key: "geo-auto-update", persistent: true)
                                NumRow("更新间隔 (小时)", key: "geo-update-interval", persistent: true)
                            }
                            Text("DAT 模式使用 v2ray (.dat) 替代 MaxMind (.mmdb) 进行 GeoIP 匹配，文件更小；推荐“内存优先”加载器以降低后台占用。")
                                .font(.dsBody).foregroundColor(.secondary).padding(.top, DS.Spacing.s)
                        }

                        // 外部面板
                        Card(title: "外部面板", icon: "macwindow.on.rectangle") {
                            VStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Zashboard URL").font(.dsBody).foregroundColor(.secondary)
                                    TextField("https://board.zash.run.place/", text: $M.zashboardURL)
                                        .inputStyle()
                                        .font(.dsMono)
                                }
                            }
                        }
                    } else if selectedTab == "advanced" {
                        // 路由与连接
                        Card(title: "路由与连接", icon: "arrow.triangle.branch") {
                            VStack(spacing: 2) {
                                PickerRow("日志级别", key: "log-level", options: [("silent","静默"),("error","error"),("warning","warning"),("info","info"),("debug","debug")], persistent: true)
                                ToggleRow("TCP 并发连接", key: "tcp-concurrent", persistent: true)
                                ToggleRow("统一延迟测速", key: "unified-delay", persistent: true)
                                TextRow("绑定网卡", key: "interface-name", placeholder: "自动", persistent: true)
                                PickerRow("进程匹配", key: "find-process-mode", options: [("always","总是"),("strict","严格"),("off","关闭")], persistent: true)
                                NumRow("Keep-Alive 间隔 (秒)", key: "keep-alive-interval", persistent: true)
                                NumRow("Keep-Alive 空闲 (秒)", key: "keep-alive-idle", persistent: true)
                                ToggleRow("禁用 Keep-Alive", key: "disable-keep-alive", persistent: true)
                            }
                            Text("TCP 并发能极大加快多节点测速；统一延迟将握手时间计入以反映真实体感延迟；进程匹配使 macOS 能按 App 名分流。")
                                .font(.dsBody).foregroundColor(.secondary).padding(.top, DS.Spacing.s)
                        }

                        // GEO 下载源
                        Card(title: "GEO 下载源", icon: "arrow.down.circle") {
                            VStack(spacing: 2) {
                                GeoURLRow("GeoIP", sub: "geoip", defaultURL: "https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geoip.dat")
                                GeoURLRow("GeoSite", sub: "geosite", defaultURL: "https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/geosite.dat")
                                GeoURLRow("MMDB", sub: "mmdb", defaultURL: "https://cdn.jsdelivr.net/gh/Loyalsoldier/v2ray-rules-dat@release/country.mmdb")
                                GeoURLRow("ASN", sub: "asn", defaultURL: "https://github.com/P3TERX/GeoLite.mmdb/raw/download/GeoLite2-ASN.mmdb")
                            }
                            Text("修改下载源 URL 后会在下次更新时生效。")
                                .font(.dsBody).foregroundColor(.secondary).padding(.top, DS.Spacing.s)
                        }
                        // 内核管理已移至「网络 → 内核」,此处不再重复。
                    } else if selectedTab == "privilege" {
                        Card(title: "系统权限", icon: "shield") {
                            VStack(alignment: .leading, spacing: DS.Spacing.l) {
                                HStack(spacing: DS.Spacing.m) {
                                    Image(systemName: engine.isRoot ? "shield.checkmark.fill" : "shield.fill")
                                        .font(DS.Icon.font(DS.Icon.lg))
                                        .foregroundColor(engine.isRoot ? DS.Palette.ok : .secondary)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("特权辅助程序")
                                            .font(.dsCardLabel)
                                            .foregroundColor(engine.isRoot ? DS.Palette.ok : .primary)
                                        Text(engine.isRoot ? "已启用特权服务，日常操作免密" : "未安装或未启用特权服务")
                                            .font(.dsBody)
                                            .foregroundColor(.secondary)
                                    }

                                    Spacer()

                                    Button(action: { Task { await toggleHelper() } }) {
                                        if helperBusy {
                                            ProgressView().controlSize(.small)
                                        } else if helperNeedsUpdate {
                                            Text("更新")
                                        } else {
                                            Text(engine.isRoot ? "卸载" : "安装")
                                        }
                                    }
                                    .dsButton(helperNeedsUpdate ? .warning : (engine.isRoot ? .destructive : .prominent))
                                    .disabled(helperBusy)
                                }

                                Divider()

                                HStack {
                                    Text("版本")
                                        .font(.dsBody)
                                    Spacer()
                                    if helperNeedsUpdate {
                                        Text("\(engine.helperVersion) → \(EngineControl.kExpectedHelperVersion)")
                                            .font(.dsMono)
                                            .foregroundColor(DS.Palette.warn)
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .foregroundColor(DS.Palette.warn)
                                            .font(.dsBody)
                                    } else {
                                        Text(engine.helperVersion)
                                            .font(.dsMono)
                                            .foregroundColor(.secondary)
                                    }
                                    Button("检查") {
                                        engine.refreshHelperVersion()
                                        M.showToast(engine.isRoot ? "Helper 连通正常 · v\(engine.helperVersion)" : "Helper 未连通", kind: engine.isRoot ? .ok : .error)
                                    }
                                    .dsButton()

                                }
                            }
                            .padding(.vertical, DS.Spacing.xs)
                        }

                        Text("ClashHalo 需要“特权辅助程序”才能安全地为您接管系统网络路由及代理设置。")
                            .font(.dsBody)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, DS.Spacing.xs)
                            .padding(.top, DS.Spacing.xs)
                    } else if selectedTab == "about" {
                        aboutView
                    }
                }
                .padding(DS.Spacing.xl)
            }
        }
    }

    /// 关于页：工具型 Card 堆叠（design.md §1/§6），禁止居中 hero / 营销文案。
    private var aboutView: some View {
        let appVersion = ContentView.appVersion
        let appBuild = ContentView.appBuild
        let helperVersion = engine.helperVersion.isEmpty || engine.helperVersion == "?"
            ? "—"
            : engine.helperVersion
        let kernelVersion = M.reachable ? M.version : "—"
        let projectURL = URL(string: "https://github.com/\(M.updater.repoOwner)/\(M.updater.repoName)")!
        let mihomoURL = URL(string: "https://github.com/MetaCubeX/mihomo")!
        let issuesURL = URL(string: "https://github.com/\(M.updater.repoOwner)/\(M.updater.repoName)/issues")!

        return VStack(alignment: .leading, spacing: DS.Spacing.m) {
            // 应用身份：左 icon + 名称版本，右状态点（非营销 hero）
            Card {
                HStack(spacing: DS.Spacing.m) {
                    Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                        .resizable()
                        .interpolation(.high)
                        .frame(width: DS.Icon.xl, height: DS.Icon.xl)
                        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))

                    VStack(alignment: .leading, spacing: DS.Spacing.xs / 2) {
                        Text("ClashHalo")
                            .font(.dsCardLabel)
                        Text("v\(appVersion) · build \(appBuild)")
                            .font(.dsMono)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)

                    HStack(spacing: DS.Spacing.s) {
                        Circle()
                            .fill(M.reachable ? DS.Palette.ok : DS.Palette.error)
                            .frame(width: 6, height: 6)
                        Text(M.reachable ? "核心运行中" : "核心已停止")
                            .font(.dsBody)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // 版本明细
            Card(title: "版本信息", icon: "info.circle") {
                VStack(spacing: 0) {
                    aboutKVRow("应用版本", "v\(appVersion)")
                    aboutKVRow("构建号", appBuild)
                    aboutKVRow("内核 (mihomo)", kernelVersion)
                    aboutKVRow("特权 Helper", helperVersion, last: true)
                }
            }

            // 更新
            Card(title: "应用更新", icon: "arrow.down.circle") {
                VStack(alignment: .leading, spacing: DS.Spacing.m) {
                    HStack(alignment: .center, spacing: DS.Spacing.m) {
                        Circle()
                            .fill(updateStatusColor)
                            .frame(width: 6, height: 6)
                        VStack(alignment: .leading, spacing: DS.Spacing.xs / 2) {
                            Text(updateStatusTitle)
                                .font(.dsBodyMedium)
                                .foregroundStyle(updateStatusColor == DS.Palette.warn ? DS.Palette.warn : .primary)
                            if let detail = updateStatusDetail {
                                Text(detail)
                                    .font(.dsBody)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        Spacer(minLength: 0)

                        if M.updater.updateAvailable {
                            Button("下载更新") {
                                Task {
                                    M.showToast("开始下载更新...")
                                    let ok = await M.updater.performUpdate()
                                    M.showToast(ok ? "更新包已打开，请按提示安装" : "更新下载失败", kind: ok ? .ok : .error)
                                }
                            }
                            .dsButton(.warning)
                            .disabled(M.updater.isDownloading)
                        }

                        Button {
                            Task { _ = await M.updater.checkForUpdates() }
                        } label: {
                            if M.updater.isChecking {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("检查更新")
                            }
                        }
                        .dsButton()
                        .disabled(M.updater.isChecking || M.updater.isDownloading)
                    }

                    if M.updater.isDownloading {
                        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                            ProgressView(value: M.updater.downloadProgress)
                                .progressViewStyle(.linear)
                                .tint(DS.Palette.accent)
                            Text("下载中 \(Int(M.updater.downloadProgress * 100))%")
                                .font(.dsCaption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if M.updater.updateAvailable, let notes = M.updater.releaseNotes, !notes.isEmpty {
                        Text(notes)
                            .font(.dsBody)
                            .foregroundStyle(.secondary)
                            .lineLimit(6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(DS.Spacing.m)
                            .background(
                                RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                                    .fill(DS.Palette.fillFaint)
                            )
                    }
                }
            }

            // 链接与许可
            Card(title: "开源与链接", icon: "link") {
                VStack(spacing: 0) {
                    aboutLinkRow("项目主页", "GitHub · \(M.updater.repoOwner)/\(M.updater.repoName)", url: projectURL)
                    aboutLinkRow("问题反馈", "Issues", url: issuesURL)
                    aboutLinkRow("代理内核", "mihomo (Clash.Meta)", url: mihomoURL, last: true)
                }
            }

            Card(title: "说明", icon: "doc.text") {
                VStack(alignment: .leading, spacing: DS.Spacing.s) {
                    Text("macOS 原生 SwiftUI 客户端，直接编排 mihomo 内核。特权操作经独立 Helper (XPC) 执行；订阅 URL 存 Keychain。")
                        .font(.dsBody)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("仅用于网络技术学习与管理，不提供任何代理节点服务。请遵守所在地法律法规。")
                        .font(.dsBody)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("© 2026 ClashHalo · MIT License")
                        .font(.dsCaption)
                        .foregroundStyle(.secondary)
                        .padding(.top, DS.Spacing.xs)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var updateStatusColor: Color {
        if M.updater.isChecking || M.updater.isDownloading { return DS.Palette.info }
        if M.updater.updateAvailable { return DS.Palette.warn }
        if M.updater.latestVersion != nil { return DS.Palette.ok }
        return DS.Palette.separator
    }

    private var updateStatusTitle: String {
        if M.updater.isChecking { return "正在检查更新…" }
        if M.updater.isDownloading { return "正在下载更新…" }
        if M.updater.updateAvailable, let v = M.updater.latestVersion {
            return "发现新版本 v\(v)"
        }
        if M.updater.latestVersion != nil { return "当前已是最新版本" }
        return "尚未检查更新"
    }

    private var updateStatusDetail: String? {
        if M.updater.isChecking || M.updater.isDownloading { return nil }
        if M.updater.updateAvailable {
            return "当前 v\(ContentView.appVersion) (build \(ContentView.appBuild)) · 可从 GitHub Releases 下载"
        }
        if let latest = M.updater.latestVersion {
            return "远端最新 v\(latest) · 本地 v\(ContentView.appVersion) (build \(ContentView.appBuild))"
        }
        return "通过 GitHub Releases 检查新版本"
    }

    private func aboutKVRow(_ label: String, _ value: String, last: Bool = false) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Spacing.s) {
                Text(label)
                    .font(.dsBody)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(value)
                    .font(.dsMono)
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .lineLimit(1)
            }
            .padding(.vertical, DS.Spacing.s)
            if !last {
                Divider().overlay(DS.Palette.separator)
            }
        }
    }

    private func aboutLinkRow(_ title: String, _ subtitle: String, url: URL, last: Bool = false) -> some View {
        VStack(spacing: 0) {
            Link(destination: url) {
                HStack(spacing: DS.Spacing.s) {
                    VStack(alignment: .leading, spacing: DS.Spacing.xs / 2) {
                        Text(title)
                            .font(.dsBodyMedium)
                            .foregroundStyle(.primary)
                        Text(subtitle)
                            .font(.dsCaption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right")
                        .font(DS.Icon.font(DS.Icon.sm))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, DS.Spacing.s)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if !last {
                Divider().overlay(DS.Palette.separator)
            }
        }
    }

    var statusLine: String {
        if !M.reachable { return "未连接内核" }
        return "已连接 · mihomo \(M.version)"
    }
    func field(_ l: String, text: Binding<String>, placeholder: String) -> some View {
        HStack {
            Text(l).font(.dsBody).foregroundColor(.secondary).frame(width: 50, alignment: .leading)
            TextField(placeholder, text: text).inputStyle()
        }
    }


    /// True when helper is installed but its version is below the expected version.
    private var helperNeedsUpdate: Bool {
        engine.isRoot &&
        engine.helperVersion != "?" &&
        !engine.helperVersion.isEmpty &&
        engine.helperVersion != EngineControl.kExpectedHelperVersion
    }

    /// Install / uninstall / upgrade the privileged helper with progress + clear feedback.
    /// - Installed + outdated → upgrade (uninstall then reinstall, full cycle)
    /// - Installed + current  → uninstall
    /// - Not installed        → install
    private func toggleHelper() async {
        helperBusy = true
        defer { helperBusy = false }
        if engine.isRoot && helperNeedsUpdate {
            M.showToast("正在更新特权服务（v\(engine.helperVersion) → v\(EngineControl.kExpectedHelperVersion)）…")
            let upgraded = await engine.checkAndUpgradeHelperIfNeeded()
            guard upgraded else { M.showToast("更新失败或已取消", kind: .error); return }
            await M.reconnect()
            M.showToast("特权服务已更新 ✓", kind: .ok)
        } else if engine.isRoot {
            M.showToast("正在请求授权卸载特权服务…")
            let ok = await engine.uninstallPrivileged()
            await M.reconnect()
            M.showToast(ok ? "特权辅助程序已卸载" : "卸载失败或已取消", kind: ok ? .ok : .error)
        } else {
            M.showToast("正在请求授权安装特权服务…")
            let ok = await engine.installPrivileged()
            guard ok else { M.showToast("安装失败或已取消", kind: .error); return }
            // installPrivileged osascript 成功即视为安装完成；连通状态由 pollStatus 异步更新
            engine.isRoot = true
            await waitForHelper()
            await M.reconnect()
            M.showToast("特权辅助程序已安装 ✓", kind: .ok)
        }
    }

    /// Poll verifyConnectivity up to 15s; return regardless (state updated async by pollStatus).
    private func waitForHelper() async {
        for _ in 0..<30 {
            if await XPCManager.shared.verifyConnectivity() { return }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }
}

// MARK: - Menu Bar

struct MenuBarPanel: View {
    @EnvironmentObject var M: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            // Header + inline status (serves as toast surface when the main window is hidden)
            HStack(spacing: DS.Spacing.s) {
                Image(systemName: "bolt.fill").font(DS.Icon.font(DS.Icon.md)).foregroundColor(DS.Palette.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text("ClashHalo").font(.dsCardLabel)
                    if let toast = M.toast {
                        HStack(spacing: DS.Spacing.xs) {
                            Circle().fill(menuBarToastColor(toast.kind)).frame(width: 5, height: 5)
                            Text(toast.text)
                                .font(.dsBody)
                                .foregroundColor(.secondary)
                                .lineLimit(2)
                        }
                    } else {
                        HStack(spacing: DS.Spacing.xs) {
                            Circle().fill(M.reachable ? DS.Palette.ok : DS.Palette.error).frame(width: 5, height: 5)
                            Text(M.reachable ? "mihomo \(M.version)" : "未连接").font(.dsBody).foregroundColor(.secondary)
                        }
                    }
                }
                Spacer()
            }
            .padding(.horizontal, DS.Spacing.xs).padding(.top, DS.Spacing.xs)
            .animation(DS.Motion.toast, value: M.toast)

            // Switches card
            card {
                switchRow("系统代理", icon: "globe",
                          isOn: Binding(
                            get: { M.systemProxyOn },
                            set: { newValue in
                                guard newValue != M.systemProxyOn else { return }
                                M.toggleSystemProxy()
                            }))
                switchRow("TUN 模式", icon: "shield", accent: true,
                          isOn: Binding(
                            get: { M.tunOn },
                            set: { newValue in
                                guard newValue != M.tunOn else { return }
                                M.toggleTUN()
                            }))
                switchRow("核心运行", icon: "bolt",
                          isOn: Binding(
                            get: { M.reachable },
                            set: { newValue in
                                guard newValue != M.reachable else { return }
                                M.toggleEngine()
                            }))
            }

            // Proxy card: mode · per-group node selectors · live rate · test
            card {
                DSSegmentedControl(selection: Binding(
                    get: { M.mode },
                    set: { M.setMode($0) }
                ), choices: [
                    DSChoice("规则", "rule"),
                    DSChoice("全局", "global"),
                    DSChoice("直连", "direct")
                ])

                if M.menuBarGroups {
                    let selectable = M.groups.filter { $0.selectable }
                    if selectable.isEmpty {
                        Text(M.reachable ? "无可选策略组" : "未连接内核")
                            .font(.dsBody).foregroundColor(.secondary)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(Array(selectable.enumerated()), id: \.element.id) { idx, g in
                                groupSelector(g)
                                if idx < selectable.count - 1 { Divider().opacity(0.25) }
                            }
                        }
                    }
                }

                Divider().opacity(0.4)

                HStack(spacing: DS.Spacing.s) {
                    Label(fmtRate(Double(M.curDown)), systemImage: "arrow.down").font(.dsMono)
                    Spacer()
                    Label(fmtRate(Double(M.curUp)), systemImage: "arrow.up").font(.dsMono).foregroundColor(.secondary)
                }
                if M.menuBarGroups {
                    Button { M.testAll() } label: {
                        HStack(spacing: DS.Spacing.xs) {
                            Image(systemName: "bolt.fill").font(.dsBody)
                            Text("全部测速").font(.dsBody)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, DS.Spacing.s)
                        .background(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).fill(DS.Palette.fill))
                        .foregroundColor(DS.Palette.accent)
                    }.buttonStyle(.plain).disabled(M.groups.isEmpty)
                }
            }

            // Config card: profile list (tap to switch) + update subscriptions
            card {
                HStack {
                    Text("配置").font(.dsBodyMedium)
                    Spacer()
                    if M.store.profiles.contains(where: { $0.source == "remote" }) {
                        Button { M.updateAllSubscriptions() } label: {
                            HStack(spacing: DS.Spacing.xs) {
                                Image(systemName: "arrow.clockwise").font(.dsBody)
                                Text("更新订阅").font(.dsBody)
                            }.foregroundColor(DS.Palette.accent)
                        }.buttonStyle(.plain)
                    }
                }
                if M.store.profiles.isEmpty {
                    Text("无配置，请在「配置编辑」导入").font(.dsBody).foregroundColor(.secondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(M.store.profiles.enumerated()), id: \.element.id) { idx, p in
                            profileRow(p)
                            if idx < M.store.profiles.count - 1 { Divider().opacity(0.25) }
                        }
                    }
                }
            }

            // Memory usage card
            card {
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Image(systemName: "memorychip").font(.dsBody).foregroundColor(DS.Palette.roleOray)
                            Text("核心内存").font(.dsBodyMedium).foregroundColor(.secondary)
                        }
                        Text(fmtBytes(Double(M.memory))).font(.dsCardLabel)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Rectangle().fill(DS.Palette.separator).frame(width: 1, height: 24)
                        .padding(.horizontal, DS.Spacing.m)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            Image(systemName: "app.dashed").font(.dsBody).foregroundColor(DS.Palette.warn)
                            Text("应用内存").font(.dsBodyMedium).foregroundColor(.secondary)
                        }
                        Text(String(format: "%.0f MB", M.appMemoryMB)).font(.dsCardLabel)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            // Quick actions (pill tiles)
            HStack(spacing: DS.Spacing.s) {
                pill("复制命令", "terminal") { M.copyProxyCommand() }
                pill("重载", "arrow.clockwise") { M.reloadActiveConfig() }
                pill("清 DNS", "trash") { M.clearAllCache() }
            }
            // Navigation (pill tiles)
            HStack(spacing: DS.Spacing.s) {
                pill("仪表盘", "gauge") { go("dashboard") }
                pill("连接", "link") { go("connections") }
                pill("日志", "doc.plaintext.fill") { go("logs") }
                pill("目录", "folder") { M.openConfigDir() }
            }

            // Preferences card
            card {
                switchRow("开机自启动", icon: "power",
                          isOn: Binding(get: { M.launchAtLoginOn }, set: { M.setLaunchAtLogin($0) }))
                switchRow("显示 Dock 图标", icon: "dock.rectangle",
                          isOn: Binding(get: { M.showDock }, set: { M.setShowDock($0) }))
            }

            Divider().padding(.vertical, DS.Spacing.xs)
            // Action row — open main window / quit (Burrow-style)
            HStack {
                Button { go(M.route) } label: {
                    Text("打开 ClashHalo").font(.dsCardLabel)
                }.buttonStyle(.plain)
                Spacer()
                Button { NSApplication.shared.terminate(nil) } label: {
                    Image(systemName: "power").font(DS.Icon.font(DS.Icon.sm)).foregroundColor(.secondary)
                }.buttonStyle(.plain).help("退出 ClashHalo")
            }.padding(.horizontal, DS.Spacing.xs)
        }
        .padding(DS.Spacing.m)
        .frame(width: 300)
        .onAppear { M.isMenuBarVisible = true }
        .onDisappear { M.isMenuBarVisible = false }
    }

    /// Open the main window focused on a given route.
    private func go(_ route: String) {
        M.route = route
        M.activateApp()
        openWindow(id: "main")
    }

    private func menuBarToastColor(_ kind: ToastKind) -> Color {
        switch kind {
        case .info: return DS.Palette.info
        case .ok: return DS.Palette.ok
        case .warn: return DS.Palette.warn
        case .error: return DS.Palette.error
        }
    }

    /// Rounded card container (Burrow-style elevated surface).
    @ViewBuilder
    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) { content() }
            .padding(DS.Spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .dsCardChrome()
    }

    /// One profile row: tap to activate; active = accent checkmark + primary text.
    private func profileRow(_ p: Profile) -> some View {
        let active = p.id == M.store.activeID
        return Button { M.selectForApply(p.id) } label: {
            HStack(spacing: DS.Spacing.s) {
                Image(systemName: active ? "checkmark.circle.fill" : "circle")
                    .font(.dsBody).foregroundColor(active ? DS.Palette.accent : .secondary)
                Image(systemName: p.source == "remote" ? "icloud.fill" : "doc.fill")
                    .font(.dsBody).foregroundColor(.secondary).frame(width: 14)
                Text(p.name).font(.dsBodyMedium).foregroundColor(active ? .primary : .secondary).lineLimit(1)
                Spacer()
            }
            .padding(.vertical, DS.Spacing.xs)
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    /// One policy-group row: name on the left, a menu of its nodes on the right
    /// showing the current selection with a latency-coloured dot.
    private func groupSelector(_ g: ProxyGroup) -> some View {
        HStack(spacing: DS.Spacing.s) {
            Text(g.name).font(.dsBody).foregroundColor(.secondary).lineLimit(1)
            Spacer(minLength: DS.Spacing.s)
            DSMenuPicker(selection: Binding(
                get: { g.now },
                set: { M.select(group: g.id, name: $0) }
            ), choices: g.all.map { DSChoice($0, $0) })
            .frame(width: 180)
        }
        .padding(.vertical, DS.Spacing.xs)
    }

    /// Compact toggle row: status dot + icon + label + mini switch (DS-styled).
    /// When the engine is busy, the switch is disabled and a mini Progress is shown
    /// so menu-bar toggles match the sidebar's busy affordance.
    private func switchRow(_ label: String, icon: String, accent: Bool = false,
                           isOn: Binding<Bool>) -> some View {
        let busy = M.engine.isBusy
        return HStack(spacing: DS.Spacing.s) {
            Circle()
                .fill(isOn.wrappedValue ? (accent ? DS.Palette.accent : DS.Palette.ok) : Color.secondary.opacity(0.3))
                .frame(width: 6, height: 6)
            Image(systemName: icon).font(.dsBody)
                .foregroundColor(isOn.wrappedValue ? .primary : .secondary)
                .frame(width: 16)
            Text(label).font(.dsBodyMedium)
                .foregroundColor(busy ? .secondary : (isOn.wrappedValue ? .primary : .secondary))
            Spacer()
            if busy {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(DS.Progress.miniScale)
            }
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .tint(accent ? DS.Palette.accent : DS.Palette.ok)
                .disabled(busy)
                .opacity(busy ? 0.55 : 1)
        }
    }

    /// Equal-width action tile: icon over caption. Uses the same solid surface +
    /// border as the cards (not a translucent fill) so every block reads identically
    /// over the menu-bar's vibrancy background.
    private func pill(_ label: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: DS.Spacing.xs) {
                Image(systemName: icon).font(.dsBody)
                Text(label).font(.dsBody)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, DS.Spacing.s)
            .dsControlChrome()
            .foregroundColor(.secondary)
        }.buttonStyle(.plain)
    }
}

// MARK: - Shared empty state
//
// design.md §6.6：居中、弱图标、单行/两行说明，无插画。
// 调用方放在 chrome 下方的剩余区域即可；组件自身填满并垂直居中，
// 禁止再叠 padding.top / minHeight 魔术数，否则各页图标位置会漂移。

struct ContentUnavailable: View {
    let text: String
    let icon: String

    init(_ text: String, _ icon: String) {
        self.text = text
        self.icon = icon
    }

    var body: some View {
        VStack(spacing: DS.Spacing.m) {
            Image(systemName: icon)
                .font(DS.Icon.font(DS.Icon.xl))
                .foregroundStyle(.secondary.opacity(0.45))
                .symbolRenderingMode(.hierarchical)
            Text(text)
                .font(.dsBody)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, DS.Spacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        // ScrollView 内无界高度时仍保持可扫描的最小占位，避免塌成一条
        .frame(minHeight: 240)
    }
}


#Preview("Settings") {
    GeneralPage().environmentObject(AppModel.shared)
        .frame(minWidth: 900, idealWidth: 1000, maxWidth: 1200, minHeight: 720, idealHeight: 800, maxHeight: 1000)
}
