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
                                    Text("深色模式").font(.dsBody)
                                    Spacer()
                                    Toggle("", isOn: $M.dark)
                                        .toggleStyle(.switch)
                                        .labelsHidden()
                                        .frame(width: 160, alignment: .trailing)
                                }
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
                                    .frame(width: 160, alignment: .trailing)
                                }
                            }
                        }

                        // GEO 数据库
                        Card(title: "GEO 数据库", icon: "globe.asia.australia") {
                            VStack(spacing: 2) {
                                ToggleRow("DAT 模式", key: "geodata-mode")
                                PickerRow("加载器", key: "geodata-loader", options: [("memconservative","内存优先"),("standard","标准")])
                                ToggleRow("自动更新", key: "geo-auto-update")
                                NumRow("更新间隔 (小时)", key: "geo-update-interval")
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
                                ToggleRow("统一延迟测速", key: "unified-delay")
                                TextRow("绑定网卡", key: "interface-name", placeholder: "自动")
                                PickerRow("进程匹配", key: "find-process-mode", options: [("always","总是"),("strict","严格"),("off","关闭")])
                                NumRow("Keep-Alive 间隔 (秒)", key: "keep-alive-interval")
                                NumRow("Keep-Alive 空闲 (秒)", key: "keep-alive-idle")
                                ToggleRow("禁用 Keep-Alive", key: "disable-keep-alive")
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

                        // 内核管理
                        KernelCard()
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
                    .fill(active ? Color.primary.opacity(0.06) : Color.clear)
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
                Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")")
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
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "bolt.fill").foregroundColor(M.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text("ClashPow").fontWeight(.semibold)
                    HStack(spacing: 4) {
                        Circle().fill(M.reachable ? Color.green : Color.red).frame(width: 5, height: 5)
                        Text(M.reachable ? "mihomo \(M.version)" : "未连接").font(.dsBody).foregroundColor(.secondary)
                    }
                }
                Spacer()
            }.padding(14)
            Divider()
            VStack(spacing: 8) {
                HStack {
                    Label(fmtRate(Double(M.curDown)), systemImage: "arrow.down").font(.dsMono)
                    Spacer()
                    Label(fmtRate(Double(M.curUp)), systemImage: "arrow.up").font(.dsMono).foregroundColor(.secondary)
                }
                HStack {
                    Text("出口").font(.dsBody).foregroundColor(.secondary)
                    Spacer()
                    Text(M.currentProxyName()).font(.dsBody).foregroundColor(M.accent)
                }
                Picker("", selection: Binding(get: { M.mode }, set: { M.setMode($0) })) {
                    Text("规则").tag("rule"); Text("全局").tag("global"); Text("直连").tag("direct")
                }.pickerStyle(.segmented).labelsHidden()
            }.padding(14)
            Divider()
            Button("退出 ClashPow") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain).font(.dsBody).padding(12)
        }.frame(width: 260)
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

