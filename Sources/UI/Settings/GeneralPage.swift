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
            PageHead(title: "设置", desc: "应用通用偏好 · 特权辅助程序 · 进阶内核管理")

            // Premium flat tabs
            HStack(spacing: 24) {
                tabButton("通用", icon: "gearshape", tag: "general")
                tabButton("高级设置", icon: "slider.horizontal.3", tag: "advanced")
                tabButton("权限", icon: "shield", tag: "privilege")
                tabButton("关于", icon: "info.circle", tag: "about")
            }
            .padding(.horizontal, DS.Spacing.xxl)
            .padding(.bottom, DS.Spacing.l)

            Divider().opacity(0.4)

            ScrollView {
                VStack(spacing: 14) {
                    if selectedTab == "general" {
                        // 外观
                        Card(title: "外观", icon: "paintbrush") {
                            VStack(spacing: 10) {
                                HStack {
                                    Text("强调色").font(.dsBody)
                                    Spacer()
                                    HStack(spacing: 8) {
                                        ForEach(["green","blue","purple","orange"], id: \.self) { c in
                                            Circle().fill(colorFor(c)).frame(width: 22, height: 22)
                                                .overlay(Circle().stroke(Color.primary, lineWidth: M.accentRaw == c ? 2 : 0))
                                                .onTapGesture { M.accentRaw = c }
                                        }
                                    }
                                    .frame(width: DS.Layout.fieldTrailing, alignment: .trailing)
                                }
                            }
                        }

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
                                .font(.dsBody).foregroundColor(.secondary).padding(.top, 6)
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
                                .font(.dsBody).foregroundColor(.secondary).padding(.top, 6)
                        }
                    } else if selectedTab == "advanced" {
                        // 路由与连接
                        Card(title: "路由与连接", icon: "arrow.triangle.branch") {
                            VStack(spacing: 2) {
                                PickerRow("日志级别", key: "log-level", options: [("silent","静默"),("error","error"),("warning","warning"),("info","info"),("debug","debug")])
                                ToggleRow("TCP 并发连接", key: "tcp-concurrent")
                                ToggleRow("统一延迟测速", key: "unified-delay", persistent: true)
                                TextRow("绑定网卡", key: "interface-name", placeholder: "自动")
                                PickerRow("进程匹配", key: "find-process-mode", options: [("always","总是"),("strict","严格"),("off","关闭")], persistent: true)
                                NumRow("Keep-Alive 间隔 (秒)", key: "keep-alive-interval", persistent: true)
                                NumRow("Keep-Alive 空闲 (秒)", key: "keep-alive-idle", persistent: true)
                                ToggleRow("禁用 Keep-Alive", key: "disable-keep-alive", persistent: true)
                            }
                            Text("TCP 并发能极大加快多节点测速；统一延迟将握手时间计入以反映真实体感延迟；进程匹配使 macOS 能按 App 名分流。")
                                .font(.dsBody).foregroundColor(.secondary).padding(.top, 6)
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
                                .font(.dsBody).foregroundColor(.secondary).padding(.top, 6)
                        }
                        // 内核管理已移至「网络 → 内核」,此处不再重复。
                    } else if selectedTab == "privilege" {
                        Card(title: "系统权限", icon: "shield") {
                            VStack(alignment: .leading, spacing: 16) {
                                HStack(spacing: 12) {
                                    Image(systemName: engine.isRoot ? "shield.checkmark.fill" : "shield.fill")
                                        .font(.system(size: DS.Icon.lg))
                                        .foregroundColor(engine.isRoot ? .green : .secondary)
                                    
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("特权辅助程序")
                                            .font(.dsCardLabel)
                                            .foregroundColor(engine.isRoot ? .green : .primary)
                                        Text(engine.isRoot ? "已启用特权服务，日常操作免密" : "未安装或未启用特权服务")
                                            .font(.dsBody)
                                            .foregroundColor(.secondary)
                                    }
                                    
                                    Spacer()
                                    
                                    Button(action: { Task { await toggleHelper() } }) {
                                        Group {
                                            if helperBusy {
                                                ProgressView().controlSize(.small)
                                            } else if helperNeedsUpdate {
                                                Text("更新")
                                                    .foregroundColor(.white)
                                                    .fontWeight(.medium)
                                            } else {
                                                Text(engine.isRoot ? "卸载" : "安装")
                                                    .foregroundColor(engine.isRoot ? .red : .white)
                                                    .fontWeight(.medium)
                                            }
                                        }
                                        .frame(minWidth: 44)
                                        .padding(.horizontal, DS.Spacing.l)
                                        .padding(.vertical, 6)
                                        .background(
                                            RoundedRectangle(cornerRadius: 6)
                                                .fill(helperNeedsUpdate ? Color.orange :
                                                      engine.isRoot ? Color.red.opacity(0.15) : M.accent)
                                        )
                                    }
                                    .buttonStyle(.plain)
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
                                            .foregroundColor(.orange)
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .foregroundColor(.orange)
                                            .font(.dsBody)
                                    } else {
                                        Text(engine.helperVersion)
                                            .font(.dsMono)
                                            .foregroundColor(.secondary)
                                    }
                                    Button(action: {
                                        engine.refreshHelperVersion()
                                        M.showToast(engine.isRoot ? "Helper 连通正常 · v\(engine.helperVersion)" : "Helper 未连通")
                                    }) {
                                        Text("检查")
                                            .padding(.horizontal, 12)
                                            .padding(.vertical, 4)
                                            .background(
                                                RoundedRectangle(cornerRadius: 6)
                                                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                                            )
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.vertical, 4)
                        }

                        Text("ClashPow 需要“特权辅助程序”才能安全地为您接管系统网络路由及代理设置。")
                            .font(.dsBody)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 4)
                            .padding(.top, 4)
                    } else if selectedTab == "about" {
                        aboutView
                    }
                }
                .padding(DS.Spacing.xl)
            }
        }
    }

    private func tabButton(_ label: String, icon: String, tag: String) -> some View {
        let active = selectedTab == tag
        let activeIcon: String
        let inactiveIcon: String
        
        switch tag {
        case "general":
            activeIcon = "gearshape.fill"
            inactiveIcon = "gearshape"
        case "advanced":
            activeIcon = "slider.horizontal.3"
            inactiveIcon = "slider.horizontal.3"
        case "privilege":
            activeIcon = "shield.fill"
            inactiveIcon = "shield"
        case "about":
            activeIcon = "info.circle.fill"
            inactiveIcon = "info.circle"
        default:
            activeIcon = icon
            inactiveIcon = icon
        }
        
        return Button(action: { selectedTab = tag }) {
            VStack(spacing: 6) {
                Image(systemName: active ? activeIcon : inactiveIcon)
                    .font(.system(size: DS.Icon.md))
                    .foregroundColor(active ? M.accent : .secondary)
                Text(label)
                    .font(.system(size: 12, weight: active ? .semibold : .regular))
                    .foregroundColor(active ? .primary : .secondary)
            }
            .frame(width: 80)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.control)
                    .fill(active ? DS.Palette.fill : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    private var aboutView: some View {
        VStack(spacing: 20) {
            Image(systemName: "bolt.fill")
                .font(.system(size: DS.Icon.hero))
                .foregroundColor(M.accent)
                .padding(.top, 20)
            
            VStack(spacing: 4) {
                Text("ClashPow")
                    .font(.dsSection)
                    .fontWeight(.bold)
                Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—") (build \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"))")
                    .font(.dsBody)
                    .foregroundColor(.secondary)
            }

            Text("ClashPow 是一个基于 mihomo (Clash.Meta) 内核的 macOS 原生代理客户端。采用原生 SwiftUI 编写，通过独立特权 Helper (XPC) 进行权限分离，订阅凭据经 Keychain 安全存储。")
                .font(.dsBody)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
                .padding(.horizontal, 40)
                .fixedSize(horizontal: false, vertical: true)
            
            VStack(spacing: 8) {
                Link(destination: URL(string: "https://github.com/MetaCubeX/mihomo")!) {
                    Label("mihomo (Clash.Meta) 核心", systemImage: "link")
                        .font(.dsBody)
                        .foregroundColor(M.accent)
                }
            }
            .padding(.top, 10)
            
            Spacer()
            
            Text("© 2026 ClashPow Dev Team. All rights reserved.")
                .font(.dsBody)
                .foregroundColor(.secondary)
                .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity, minHeight: 350)
    }

    var statusLine: String {
        if !M.reachable { return "未连接内核" }
        return "已连接 · mihomo \(M.version)"
    }
    func field(_ l: String, text: Binding<String>, placeholder: String) -> some View {
        HStack { Text(l).font(.dsBody).foregroundColor(.secondary).frame(width: 50, alignment: .leading)
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder) }
    }
    func colorFor(_ s: String) -> Color { ["green":.green,"blue":.blue,"purple":.purple,"orange":.orange][s] ?? .green }

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
            M.showToast("正在升级特权服务（v\(engine.helperVersion) → v\(EngineControl.kExpectedHelperVersion)）…")
            let ok = await XPCManager.shared.upgradeDaemon()
            guard ok else { M.showToast("升级失败或已取消授权"); return }
            engine.isRoot = true
            await waitForHelper()
            engine.refreshHelperVersion()
            await M.reconnect()
            M.showToast("特权服务已升级 ✓")
        } else if engine.isRoot {
            M.showToast("正在请求授权卸载特权服务…")
            let ok = await engine.uninstallPrivileged()
            await M.reconnect()
            M.showToast(ok ? "特权辅助程序已卸载" : "卸载失败或已取消授权")
        } else {
            M.showToast("正在请求授权安装特权服务…")
            let ok = await engine.installPrivileged()
            guard ok else { M.showToast("安装失败或已取消授权"); return }
            // installPrivileged osascript 成功即视为安装完成；连通状态由 pollStatus 异步更新
            engine.isRoot = true
            await waitForHelper()
            await M.reconnect()
            M.showToast("特权辅助程序已安装 ✓")
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
            // Header
            HStack(spacing: DS.Spacing.s) {
                Image(systemName: "bolt.fill").font(.system(size: DS.Icon.md)).foregroundColor(M.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text("ClashPow").font(.dsCardLabel)
                    HStack(spacing: DS.Spacing.xs) {
                        Circle().fill(M.reachable ? DS.Palette.ok : DS.Palette.error).frame(width: 5, height: 5)
                        Text(M.reachable ? "mihomo \(M.version)" : "未连接").font(.dsBody).foregroundColor(.secondary)
                    }
                }
                Spacer()
            }
            .padding(.horizontal, DS.Spacing.xs).padding(.top, DS.Spacing.xs)

            // Switches card
            card {
                switchRow("系统代理", icon: "globe",
                          isOn: Binding(get: { M.systemProxyOn }, set: { _ in M.toggleSystemProxy() }))
                switchRow("TUN 模式", icon: "shield.lefthalf.filled", accent: true,
                          isOn: Binding(get: { M.tunOn }, set: { _ in M.toggleTUN() }))
                switchRow("核心运行", icon: "bolt.fill",
                          isOn: Binding(get: { M.reachable }, set: { _ in M.toggleEngine() }))
            }

            // Proxy card: mode · per-group node selectors · live rate · test
            card {
                HStack(spacing: 0) {
                    modeTab("规则", "rule")
                    modeTab("全局", "global")
                    modeTab("直连", "direct")
                }
                .padding(2)
                .background(RoundedRectangle(cornerRadius: DS.Radius.control).fill(DS.Palette.fill))

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
                        .background(RoundedRectangle(cornerRadius: DS.Radius.control).fill(DS.Palette.fill))
                        .foregroundColor(M.accent)
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
                            }.foregroundColor(M.accent)
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
                    Text("打开 ClashPow").font(.dsCardLabel)
                }.buttonStyle(.plain)
                Spacer()
                Button { NSApplication.shared.terminate(nil) } label: {
                    Image(systemName: "power").font(.system(size: DS.Icon.sm)).foregroundColor(.secondary)
                }.buttonStyle(.plain).help("退出 ClashPow")
            }.padding(.horizontal, DS.Spacing.xs)
        }
        .padding(DS.Spacing.m)
        .frame(width: 300)
    }

    /// Open the main window focused on a given route.
    private func go(_ route: String) {
        M.route = route
        M.activateApp()
        openWindow(id: "main")
    }

    /// Rounded card container (Burrow-style elevated surface).
    @ViewBuilder
    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) { content() }
            .padding(DS.Spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(DS.Palette.cardBg))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).stroke(DS.Palette.border))
    }

    /// Full-width segmented mode tab (equal thirds, selected = accent fill).
    private func modeTab(_ label: String, _ tag: String) -> some View {
        let on = M.mode == tag
        return Button { M.setMode(tag) } label: {
            Text(label).font(.dsBodyMedium)
                .frame(maxWidth: .infinity)
                .padding(.vertical, DS.Spacing.s - 2)
                .background(RoundedRectangle(cornerRadius: DS.Radius.control - 2).fill(on ? M.accent : Color.clear))
                .foregroundColor(on ? .white : .secondary)
        }.buttonStyle(.plain)
    }

    /// One profile row: tap to activate; active = accent checkmark + primary text.
    private func profileRow(_ p: Profile) -> some View {
        let active = p.id == M.store.activeID
        return Button { M.activateProfile(p.id) } label: {
            HStack(spacing: DS.Spacing.s) {
                Image(systemName: active ? "checkmark.circle.fill" : "circle")
                    .font(.dsBody).foregroundColor(active ? M.accent : .secondary)
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
            Menu {
                ForEach(g.all, id: \.self) { name in
                    Button { M.select(group: g.id, name: name) } label: {
                        let d = M.nodes[name]?.delay ?? 0
                        Text(name == g.now ? "✓ \(name)\(d > 0 ? "  \(d)ms" : "")"
                                           : "\(name)\(d > 0 ? "  \(d)ms" : "")")
                    }
                }
            } label: {
                HStack(spacing: DS.Spacing.xs) {
                    Circle().fill(delayColor(M.nodes[g.now]?.delay ?? 0)).frame(width: 6, height: 6)
                    Text(g.now).font(.dsBodyMedium).foregroundColor(.primary).lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down").font(.dsBody).foregroundColor(.secondary)
                }
            }.menuStyle(.borderlessButton).fixedSize()
        }
        .padding(.vertical, DS.Spacing.xs)
    }

    /// Compact toggle row: status dot + icon + label + mini switch (DS-styled).
    private func switchRow(_ label: String, icon: String, accent: Bool = false,
                           isOn: Binding<Bool>) -> some View {
        HStack(spacing: DS.Spacing.s) {
            Circle()
                .fill(isOn.wrappedValue ? (accent ? M.accent : DS.Palette.ok) : Color.secondary.opacity(0.3))
                .frame(width: 6, height: 6)
            Image(systemName: icon).font(.dsBody)
                .foregroundColor(isOn.wrappedValue ? .primary : .secondary)
                .frame(width: 16)
            Text(label).font(.dsBodyMedium).foregroundColor(isOn.wrappedValue ? .primary : .secondary)
            Spacer()
            Toggle("", isOn: isOn).toggleStyle(.switch).controlSize(.mini).labelsHidden()
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
            .background(RoundedRectangle(cornerRadius: DS.Radius.control).fill(DS.Palette.cardBg))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.control).stroke(DS.Palette.border))
            .foregroundColor(.secondary)
        }.buttonStyle(.plain)
    }
}

// MARK: - Shared empty state

struct ContentUnavailable: View {
    let text: String, icon: String
    init(_ t: String, _ i: String) { text = t; icon = i }
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: DS.Icon.xl)).foregroundColor(.secondary.opacity(0.5))
            Text(text).font(.dsBody).foregroundColor(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, minHeight: 160).padding(40)
    }
}


#Preview("Settings") {
    GeneralPage().environmentObject(AppModel.shared)
        .frame(width: 900, height: 720).preferredColorScheme(.dark)
}
