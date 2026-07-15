import SwiftUI

// MARK: - Network / TUN / Sniffer (read-only in stage A; editable in C/E)

private func cfgStr(_ c: [String: Any], _ k: String) -> String { c[k].map { "\($0)" } ?? "—" }
private func cfgBool(_ c: [String: Any], _ k: String) -> Bool { (c[k] as? Bool) == true }

struct NetworkPage: View {
    @EnvironmentObject var M: AppModel
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: DS.Spacing.l) {
                    Card(title: "入站端口", icon: "arrow.down.right.circle") {
                        VStack(spacing: 2) {
                            NumRow("HTTP 端口", key: "port", persistent: true)
                            NumRow("SOCKS 端口", key: "socks-port", persistent: true)
                            NumRow("混合端口", key: "mixed-port", persistent: true)
                            NumRow("Redir 端口", key: "redir-port", persistent: true)
                            NumRow("TProxy 端口", key: "tproxy-port", persistent: true)
                        }
                        Text("端口设为 0 即禁用。建议绝大多数应用使用混合端口（兼容 HTTP 与 SOCKS5）。")
                            .font(.dsBody).foregroundColor(.secondary).padding(.top, 6)
                    }
                    Card(title: "全局网络", icon: "globe") {
                        VStack(spacing: 2) {
                            ToggleRow("IPv6 支持", key: "ipv6", persistent: true)
                            ToggleRow("多路径 TCP (MPTCP)", key: "inbound-mptcp", persistent: true)
                            ToggleRow("TCP 并发连接", key: "tcp-concurrent", persistent: true)
                        }
                    }
                    Card(title: "访问控制", icon: "lock.shield") {
                        VStack(spacing: 2) {
                            ToggleRow("允许局域网连接", key: "allow-lan", persistent: true)
                            TextRow("绑定地址", key: "bind-address", placeholder: "*", persistent: true)
                            StringListRow("允许的 IP", key: "lan-allowed-ips", placeholder: "0.0.0.0/0", persistent: true)
                            StringListRow("拒绝的 IP", key: "lan-disallowed-ips", placeholder: "192.168.0.3/32", persistent: true)
                            StringListRow("代理认证", key: "authentication", placeholder: "user:pass", persistent: true)
                            StringListRow("免认证网段", key: "skip-auth-prefixes", placeholder: "127.0.0.1/8", persistent: true)
                        }
                        Text("开启“允许局域网”可将代理共享给同 Wi-Fi 下的其他设备；可用 IP 网段与认证做严格审查。")
                            .font(.dsBody).foregroundColor(.secondary).padding(.top, 6)
                    }
                    Card(title: "局域网网关 (旁路由)", icon: "network.badge.shield.half.filled") {
                        VStack(spacing: 2) {
                            HStack {
                                Text("作为网关中枢").font(.dsBody); Spacer()
                                Toggle("", isOn: Binding(get: { M.gatewayModeOn }, set: { _ in M.toggleGatewayMode() }))
                                    .toggleStyle(.switch).labelsHidden()
                            }.padding(.vertical, DS.Spacing.s)
                        }
                        Text("开启后将自动配置 IP 转发并接管局域网内其他所有设备的流量（需配合 TUN）。其他设备需将网关和 DNS 指向本机的局域网 IP。")
                            .font(.dsBody).foregroundColor(.secondary).padding(.top, 6)
                    }
                    if M.gatewayModeOn {
                        GatewayDevicesView()
                    }
                    Spacer(minLength: 0)
                }.padding(DS.Spacing.xl)
            }
        }
    }
}

struct GatewayDevicesView: View {
    @EnvironmentObject var M: AppModel
    
    var body: some View {
        Card(title: "已接入设备 (\(M.gatewayDevices.count))", icon: "desktopcomputer.network") {
            if M.gatewayDevices.isEmpty {
                Text("暂无设备接入，请确保其他设备网关和DNS已指向本机")
                    .font(.dsBody)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, DS.Spacing.m)
            } else {
                VStack(spacing: 8) {
                    let devices = Array(M.gatewayDevices.values).sorted(by: { $0.lastSeen > $1.lastSeen })
                    ForEach(devices) { dev in
                        GatewayDeviceRow(dev: dev)
                    }
                }
            }
        }
    }
}

struct GatewayDeviceRow: View {
    let dev: GatewayDevice
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(dev.ip)
                    .font(.dsMonoBold)
                HStack(spacing: 12) {
                    Label("\(dev.activeConnections) 连接", systemImage: "point.3.connected.trianglepath.dotted")
                    Label("\(dev.durationString)", systemImage: "clock")
                }
                .font(.dsCaption)
                .foregroundColor(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up")
                    Text(fmtRate(Double(dev.uploadRate)))
                        .frame(width: 72, alignment: .trailing)
                    Text(fmtBytes(Double(dev.totalUpload)))
                        .frame(width: 72, alignment: .trailing)
                }
                .foregroundColor(DS.Palette.ok)
                HStack(spacing: 4) {
                    Image(systemName: "arrow.down")
                    Text(fmtRate(Double(dev.downloadRate)))
                        .frame(width: 72, alignment: .trailing)
                    Text(fmtBytes(Double(dev.totalDownload)))
                        .frame(width: 72, alignment: .trailing)
                }
                .foregroundColor(DS.Palette.info)
            }
            .font(.dsCaption)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
    }
}

struct TunPage: View {
    @EnvironmentObject var M: AppModel
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: DS.Spacing.l) {
                    Card(title: "TUN 虚拟网卡", icon: "shield.lefthalf.filled") {
                    VStack(spacing: 2) {
                        HStack {
                            Text("启用 TUN").font(.dsBody); Spacer()
                            Toggle("", isOn: Binding(get: { M.tunOn }, set: { _ in M.toggleTUN() }))
                                .toggleStyle(.switch).labelsHidden()
                        }.padding(.vertical, DS.Spacing.s)
                        NPicker("协议栈", "tun", "stack", [("gvisor","gVisor"),("system","System"),("mixed","Mixed")])
                        NToggle("自动路由", "tun", "auto-route")
                        NToggle("自动检测网卡", "tun", "auto-detect-interface")
                        NList("DNS 劫持", "tun", "dns-hijack", placeholder: "any:53")
                        NList("路由排除网段", "tun", "route-exclude-address", placeholder: "192.168.0.0/16")
                    }
                    Text("用户态 UTUN (AF_SYSTEM)，不占 VPN 插槽。在「网络拓扑」中排除虚拟网段，可避免抢占其路由。")
                        .font(.dsBody).foregroundColor(.secondary).padding(.top, 6)
                }
                }
                Spacer(minLength: 0)
            }.padding(DS.Spacing.xl)
        }
    }
}

struct SnifferPage: View {
    @EnvironmentObject var M: AppModel
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: DS.Spacing.l) {
                    Card(title: "协议嗅探 Sniffer", icon: "scope") {
                    VStack(spacing: 2) {
                        NToggle("启用嗅探", "sniffer", "enable")
                        NToggle("覆盖目标地址", "sniffer", "override-destination")
                        NToggle("强制 DNS 映射", "sniffer", "force-dns-mapping")
                        NToggle("解析纯 IP", "sniffer", "parse-pure-ip")
                    }
                    Text("从 TLS / QUIC / HTTP 握手中提取真实域名用于分流，对走 IP 的连接尤为重要。默认嗅探协议：TLS(443,8443), HTTP(80,8080-8880), QUIC(443,8443)。修改后请重启核心生效。")
                        .font(.dsBody).foregroundColor(.secondary).padding(.top, 6)
                }
                }
                Spacer(minLength: 0)
            }.padding(DS.Spacing.xl)
        }
    }
}

private func kvRow(_ l: String, _ v: String) -> some View {
    HStack { Text(l).font(.dsBody); Spacer(); Text(v).font(.dsMono).foregroundColor(.secondary) }
}

// MARK: - Network hub (tabs: 入站 / TUN / DNS / 嗅探 / 内核)
//
// Consolidates the previously separate sidebar items into one page. DNS and
// Sniffer were implemented but unrouted (orphan) before this; kernel management
// lives here (single home, removed from Settings → 高级 to de-duplicate).

struct NetworkHubPage: View {
    @EnvironmentObject var M: AppModel
    @State private var tab = "network"
    private let tabs: [(String, String, String, String)] = [
        ("入站", "network", "arrow.down.right.circle", "arrow.down.right.circle.fill"),
        ("TUN", "tun", "shield.lefthalf.filled", "shield.lefthalf.filled"),
        ("DNS", "dns", "network", "network"),
        ("嗅探", "sniffer", "scope", "scope"),
        ("内核", "kernel", "cpu", "cpu.fill")
    ]

    var body: some View {
        VStack(spacing: 0) {
            if tab == "dns" {
                PageToolbar {
                    Button { M.flushDnsCache() } label: { Label("刷新缓存", systemImage: "arrow.clockwise") }
                        .buttonStyle(.bordered)
                    Button { M.clearAllCache() } label: { Label("清空", systemImage: "trash") }
                        .buttonStyle(.bordered)
                }
            }

            HStack(spacing: 24) {
                Spacer()
                ForEach(tabs, id: \.1) { t in
                    tabButton(t.0, tag: t.1, icon: t.2, activeIcon: t.3)
                }
                Spacer()
            }
            .padding(.horizontal, DS.Spacing.xxl)
            .padding(.top, tab == "dns" ? 0 : DS.Spacing.m)
            .padding(.bottom, DS.Spacing.l)

            Divider().overlay(DS.Palette.separator)
            Group {
                switch tab {
                case "tun": TunPage()
                case "dns": DnsPage()
                case "sniffer": SnifferPage()
                case "kernel": KernelMgmtPage()
                default: NetworkPage()
                }
            }
        }
    }

    private func tabButton(_ label: String, tag: String, icon: String, activeIcon: String) -> some View {
        let active = tab == tag
        return Button(action: { tab = tag }) {
            VStack(spacing: 6) {
                Image(systemName: active ? activeIcon : icon)
                    .font(DS.Icon.font(DS.Icon.md))
                    .foregroundColor(active ? DS.Palette.accent : .secondary)
                Text(label)
                    .font(active ? .dsBodySemibold : .dsBody)
                    .foregroundColor(active ? .primary : .secondary)
            }
            .frame(width: 80)
            .padding(.vertical, DS.Spacing.s)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                    .fill(active ? DS.Palette.fill : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Reusable config form rows (read M.configs, write via M.patch)

/// Number field bound to a top-level config key.
struct NumRow: View {
    @EnvironmentObject var M: AppModel
    let label: String; let key: String; let persistent: Bool
    init(_ label: String, key: String, persistent: Bool = false) { self.label = label; self.key = key; self.persistent = persistent }
    @State private var text = ""
    @State private var hasChanges = false
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack {
            Text(label).font(.dsBody)
            Spacer()
            HStack(spacing: 8) {
                TextField("0", text: $text)
                    .inputStyle()
                    .font(.dsMono)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
                    .focused($isFocused)
                    .onSubmit { commit() }
                    .onChange(of: text) { _, _ in
                        hasChanges = text != intStr(M.configs[key])
                    }
                    .onChange(of: isFocused) { _, focused in
                        if !focused && hasChanges { commit() }
                    }

                if hasChanges {
                    Button("应用") { commit() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }
            .frame(width: DS.Layout.fieldTrailing, alignment: .trailing)
        }
        .padding(.vertical, DS.Spacing.s)
        .onAppear { text = intStr(M.configs[key]) }
        .onChange(of: configValue) { _, _ in text = intStr(M.configs[key]); hasChanges = false }
    }
    private var configValue: String { intStr(M.configs[key]) }
    private func intStr(_ v: Any?) -> String { if let i = v as? Int { return "\(i)" }; if let d = v as? Double { return "\(Int(d))" }; return "0" }
    private func commit() {
        let n = Int(text) ?? 0
        hasChanges = false
        Task { if persistent { await M.patchPersistent([key: n]) } else { await M.patch([key: n]) } }
    }
}

/// Toggle bound to a top-level boolean config key.
struct ToggleRow: View {
    @EnvironmentObject var M: AppModel
    let label: String; let key: String; let persistent: Bool
    init(_ label: String, key: String, persistent: Bool = false) { self.label = label; self.key = key; self.persistent = persistent }
    var body: some View {
        HStack {
            Text(label).font(.dsBody)
            Spacer()
            Toggle("", isOn: Binding(
                get: { (M.configs[key] as? Bool) == true },
                set: { v in Task { if persistent { await M.patchPersistent([key: v]) } else { await M.patch([key: v]) } } }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .frame(width: DS.Layout.fieldTrailing, alignment: .trailing)
        }
        .padding(.vertical, DS.Spacing.s)
    }
}

/// Single-string field bound to a top-level config key.
struct TextRow: View {
    @EnvironmentObject var M: AppModel
    let label: String; let key: String; let placeholder: String; let persistent: Bool
    init(_ label: String, key: String, placeholder: String = "", persistent: Bool = false) { self.label = label; self.key = key; self.placeholder = placeholder; self.persistent = persistent }
    @State private var text = ""
    @State private var hasChanges = false
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack {
            Text(label).font(.dsBody)
            Spacer()
            HStack(spacing: 8) {
                TextField(placeholder, text: $text)
                    .inputStyle()
                    .font(.dsMono)
                    .multilineTextAlignment(.trailing)
                    .focused($isFocused)
                    .onSubmit { commit() }
                    .onChange(of: text) { _, _ in
                        hasChanges = text != ((M.configs[key] as? String) ?? "")
                    }
                    .onChange(of: isFocused) { _, focused in
                        if !focused && hasChanges { commit() }
                    }

                if hasChanges {
                    Button("应用") { commit() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                }
            }
            .frame(width: DS.Layout.fieldTrailing, alignment: .trailing)
        }
        .padding(.vertical, DS.Spacing.s)
        .onAppear { text = (M.configs[key] as? String) ?? "" }
        .onChange(of: M.configs[key] as? String) { _, _ in text = (M.configs[key] as? String) ?? ""; hasChanges = false }
    }
    private func commit() {
        hasChanges = false
        Task { if persistent { await M.patchPersistent([key: text]) } else { await M.patch([key: text]) } }
    }
}

/// Picker bound to a top-level string config key.
struct PickerRow: View {
    @EnvironmentObject var M: AppModel
    let label: String; let key: String; let options: [(String, String)]; let persistent: Bool
    init(_ label: String, key: String, options: [(String, String)], persistent: Bool = false) { self.label = label; self.key = key; self.options = options; self.persistent = persistent }
    var body: some View {
        HStack {
            Text(label).font(.dsBody)
            Spacer()
            Picker("", selection: Binding<String>(
                get: {
                    let val = (M.configs[key] as? String) ?? ""
                    return options.contains(where: { $0.0 == val }) ? val : (options.first?.0 ?? "")
                },
                set: { v in Task { if persistent { await M.patchPersistent([key: v]) } else { await M.patch([key: v]) } } }
            )) {
                ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
            }
            .labelsHidden()
            .dsMenuControl()
            .frame(width: DS.Layout.fieldTrailing, alignment: .trailing)
        }
        .padding(.vertical, DS.Spacing.s)
    }
}

/// Editable string-list bound to a top-level array config key.
/// Automatically validates input format based on placeholder hints (CIDR, URL, etc.).
struct StringListRow: View {
    @EnvironmentObject var M: AppModel
    let label: String; let key: String; let placeholder: String; let persistent: Bool
    init(_ label: String, key: String, placeholder: String = "", persistent: Bool = false) { self.label = label; self.key = key; self.placeholder = placeholder; self.persistent = persistent }
    @State private var items: [String] = []
    @State private var draft = ""
    private var draftValid: Bool { draft.isEmpty || validateInput(draft) }
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            Text(label).font(.dsBodyMedium)
            // Existing entries — each a chip on a subtle fill so the list reads as
            // distinct rows, clearly separated from the add field below.
            if !items.isEmpty {
                VStack(spacing: DS.Spacing.xs) {
                    ForEach(items.indices, id: \.self) { i in
                        HStack {
                            Text(items[i]).font(.dsMono).foregroundColor(.secondary)
                            Spacer()
                            Button { items.remove(at: i); commit() } label: { Image(systemName: "minus.circle").font(.dsBody) }
                                .buttonStyle(.borderless)
                        }
                        .padding(.horizontal, DS.Spacing.s).padding(.vertical, DS.Spacing.xs)
                        .background(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).fill(DS.Palette.hairline))
                    }
                }
            }
            // Add row — visually the input affordance, set apart from the list above.
            HStack(spacing: DS.Spacing.s) {
                TextField(placeholder, text: $draft)
                    .inputStyle()
                    .font(.dsMono)
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).stroke(!draftValid ? DS.Palette.error.opacity(0.7) : Color.clear, lineWidth: 1))
                Button { if !draft.isEmpty && draftValid { items.append(draft); draft = ""; commit() } } label: { Image(systemName: "plus.circle.fill") }
                    .buttonStyle(.borderless).disabled(!draftValid || draft.isEmpty)
            }
            if !draftValid {
                Text("格式无效 — 请检查输入（如 IP/CIDR: 10.0.0.0/8, URL: https://...）")
                    .font(.dsBody).foregroundColor(DS.Palette.error)
            }
        }
        .padding(.vertical, DS.Spacing.s)
        .onAppear { items = (M.configs[key] as? [Any])?.map { "\($0)" } ?? [] }
    }
    private func commit() { Task { if persistent { await M.patchPersistent([key: items]) } else { await M.patch([key: items]) } } }

    /// Infer expected format from placeholder and validate accordingly.
    private func validateInput(_ s: String) -> Bool {
        let p = placeholder.lowercased()
        if p.contains("/") && (p.contains(".") || p.contains(":")) {
            // CIDR: e.g. 10.0.0.0/8 or 192.168.0.0/16 or fd00::/8
            return s.range(of: #"^[\da-fA-F.:]+/\d{1,3}$"#, options: .regularExpression) != nil
        }
        if p.hasPrefix("http") {
            // URL
            return s.range(of: #"^https?://\S+"#, options: .regularExpression) != nil
        }
        if p.contains(":") && !p.contains("/") {
            // host:port or user:pass
            return s.contains(":")
        }
        return true // no specific validation for this placeholder
    }
}

struct GeoURLRow: View {
    @EnvironmentObject var M: AppModel
    let label: String; let sub: String; let defaultURL: String
    init(_ label: String, sub: String, defaultURL: String) { self.label = label; self.sub = sub; self.defaultURL = defaultURL }
    @State private var text = ""
    var body: some View {
        HStack {
            Text(label).font(.dsBody).frame(width: 70, alignment: .leading)
            TextField("https://…", text: $text)
                .inputStyle()
                .font(.dsMono)
                .onSubmit {
                    let geo = (M.configs["geox-url"] as? [String: Any] ?? [:])
                        .merging([sub: text]) { _, new in new }
                    Task { await M.patchPersistent(["geox-url": geo]) }
                }
        }
        .padding(.vertical, DS.Spacing.s)
        .onAppear {
            let geo = M.configs["geox-url"] as? [String: Any] ?? [:]
            text = (geo[sub] as? String) ?? defaultURL
        }
    }
}

// MARK: - Nested config form rows (parent.sub keys: dns / tun / sniffer)

@MainActor private func nestedDict(_ M: AppModel, _ parent: String) -> [String: Any] {
    M.configs[parent] as? [String: Any] ?? [:]
}

struct NToggle: View {
    @EnvironmentObject var M: AppModel
    let parent: String; let sub: String; let label: String; let persistent: Bool
    init(_ label: String, _ parent: String, _ sub: String, persistent: Bool = true) { self.label = label; self.parent = parent; self.sub = sub; self.persistent = persistent }
    var body: some View {
        HStack {
            Text(label).font(.dsBody); Spacer()
            Toggle("", isOn: Binding(
                get: { (nestedDict(M, parent)[sub] as? Bool) == true },
                set: { v in
                    // Optimistic UI update to prevent toggle flickering/rollback
                    var currentParent = M.configs[parent] as? [String: Any] ?? [:]
                    currentParent[sub] = v
                    M.configs[parent] = currentParent
                    
                    Task {
                        if persistent {
                            await M.patchPersistent([parent: [sub: v]])
                        } else {
                            await M.patch([parent: [sub: v]])
                        }
                    }
                }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .frame(width: DS.Layout.fieldTrailing, alignment: .trailing)
        }.padding(.vertical, DS.Spacing.s)
    }
}

struct NPicker: View {
    @EnvironmentObject var M: AppModel
    let parent: String; let sub: String; let label: String; let options: [(String, String)]; let persistent: Bool
    init(_ label: String, _ parent: String, _ sub: String, _ options: [(String, String)], persistent: Bool = true) {
        self.label = label; self.parent = parent; self.sub = sub; self.options = options; self.persistent = persistent
    }
    var body: some View {
        HStack {
            Text(label).font(.dsBody); Spacer()
            Picker("", selection: Binding<String>(
                get: {
                    let val = ((nestedDict(M, parent)[sub] as? String) ?? "").lowercased()
                    return options.first(where: { $0.0.lowercased() == val })?.0 ?? (options.first?.0 ?? "")
                },
                set: { v in
                    Task {
                        if persistent {
                            await M.patchPersistent([parent: [sub: v]])
                        } else {
                            await M.patch([parent: [sub: v]])
                        }
                    }
                }
            )) { ForEach(options, id: \.0) { Text($0.1).tag($0.0) } }
            .labelsHidden()
            .dsMenuControl()
            .frame(width: DS.Layout.fieldTrailing, alignment: .trailing)
        }.padding(.vertical, DS.Spacing.s)
    }
}

struct NText: View {
    @EnvironmentObject var M: AppModel
    let parent: String; let sub: String; let label: String; let placeholder: String; let persistent: Bool
    init(_ label: String, _ parent: String, _ sub: String, placeholder: String = "", persistent: Bool = true) {
        self.label = label; self.parent = parent; self.sub = sub; self.placeholder = placeholder; self.persistent = persistent
    }
    @State private var text = ""
    var body: some View {
        HStack {
            Text(label).font(.dsBody); Spacer()
            TextField(placeholder, text: $text)
                .inputStyle()
                .font(.dsMono)
                .multilineTextAlignment(.trailing)
                .onSubmit {
                    Task {
                        if persistent {
                            await M.patchPersistent([parent: [sub: text]])
                        } else {
                            await M.patch([parent: [sub: text]])
                        }
                    }
                }
                .frame(width: DS.Layout.fieldTrailing, alignment: .trailing)
        }.padding(.vertical, DS.Spacing.s)
        .onAppear { text = (nestedDict(M, parent)[sub] as? String) ?? "" }
    }
}

struct NList: View {
    @EnvironmentObject var M: AppModel
    let parent: String; let sub: String; let label: String; let placeholder: String; let persistent: Bool
    init(_ label: String, _ parent: String, _ sub: String, placeholder: String = "", persistent: Bool = true) {
        self.label = label; self.parent = parent; self.sub = sub; self.placeholder = placeholder; self.persistent = persistent
    }
    @State private var items: [String] = []
    @State private var draft = ""
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            Text(label).font(.dsBodyMedium)
            if !items.isEmpty {
                VStack(spacing: DS.Spacing.xs) {
                    ForEach(items.indices, id: \.self) { i in
                        HStack {
                            Text(items[i]).font(.dsMono).foregroundColor(.secondary); Spacer()
                            Button { items.remove(at: i); commit() } label: { Image(systemName: "minus.circle").font(.dsBody) }.buttonStyle(.borderless)
                        }
                        .padding(.horizontal, DS.Spacing.s).padding(.vertical, DS.Spacing.xs)
                        .background(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).fill(DS.Palette.hairline))
                    }
                }
            }
            HStack(spacing: DS.Spacing.s) {
                TextField(placeholder, text: $draft)
                    .inputStyle()
                    .font(.dsMono)
                Button { if !draft.isEmpty { items.append(draft); draft = ""; commit() } } label: { Image(systemName: "plus.circle.fill") }.buttonStyle(.borderless)
            }
        }.padding(.vertical, DS.Spacing.s)
        .onAppear { items = (nestedDict(M, parent)[sub] as? [Any])?.map { "\($0)" } ?? [] }
    }
    private func commit() {
        Task {
            if persistent {
                await M.patchPersistent([parent: [sub: items]])
            } else {
                await M.patch([parent: [sub: items]])
            }
        }
    }
}

// MARK: - Kernel Management Page

struct KernelMgmtPage: View {
    @EnvironmentObject var M: AppModel
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: DS.Spacing.l) {
                    KernelCard()
                    
                    Card(title: "API 控制 (外部面板)", icon: "server.rack") {
                        VStack(spacing: 2) {
                            TextRow("API 监听地址", key: "external-controller", placeholder: "127.0.0.1:9090", persistent: true)
                            TextRow("API 密钥 (Secret)", key: "secret", placeholder: "留空即无密码", persistent: true)
                            TextRow("本地面板目录", key: "external-ui", placeholder: "zashboard", persistent: true)
                            TextRow("面板解压目录名", key: "external-ui-name", placeholder: "zashboard", persistent: true)
                            TextRow("面板下载地址", key: "external-ui-url", placeholder: "https://github.com/Zephyruso/zashboard/releases/latest/download/dist-no-fonts.zip", persistent: true)
                        }
                        Text("内核内置面板 (如 Zashboard)。配置下载地址后，内核启动时会自动下载并解压到指定目录，您可通过 http://<API地址>/ui 访问。")
                            .font(.dsBody).foregroundColor(.secondary).padding(.top, 6)
                    }
                    
                    Card(title: "启动日志", icon: "terminal") {
                        VStack(alignment: .leading, spacing: 4) {
                            if M.kernelLogs.isEmpty {
                                Text("暂无启动日志").font(.dsBody).foregroundColor(.secondary)
                            } else {
                                ForEach(M.kernelLogs.indices, id: \.self) { i in
                                    Text(M.kernelLogs[i])
                                        .font(.dsMono)
                                        .foregroundColor(M.kernelLogs[i].contains("错误") ? DS.Palette.error : .primary)
                                }
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
            }.padding(DS.Spacing.xl)
        }
    }
}

// MARK: - Kernel management card (version / channel / upgrade / restart)

struct KernelCard: View {
    @EnvironmentObject var M: AppModel
    @StateObject private var km = KernelManager.shared
    var body: some View {
        Card(title: "内核管理", icon: "cpu") {
            VStack(spacing: 10) {
                HStack {
                    Circle().fill(M.reachable ? DS.Palette.ok : DS.Palette.error).frame(width: 8, height: 8)
                    Text(M.reachable ? "运行中 · mihomo \(M.version)" : "已停止").font(.dsBody).foregroundColor(.secondary)
                    Spacer()
                    if M.reachable {
                        Button("重启内核", systemImage: "arrow.triangle.2.circlepath") {
                            M.withEngineBusy {
                                let wasTUN = M.tunOn
                                await M.engine.restart(); try? await Task.sleep(nanoseconds: 3_000_000_000); await M.reconnect()
                                await M.reapplyTUN(wasOn: wasTUN)
                                M.showToast("内核已重启")
                            }
                        }.buttonStyle(.bordered).tint(DS.Palette.warn).controlSize(.small)
                    }
                    Toggle("", isOn: Binding(get: { M.reachable }, set: { _ in M.toggleEngine() }))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .labelsHidden()
                }
                Divider()
                HStack {
                    Text("更新通道").font(.dsBody)
                    Spacer()
                    Picker("", selection: $km.channel) {
                        Text("正式版").tag("stable"); Text("Alpha").tag("alpha")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: DS.Layout.fieldTrailing, alignment: .trailing)
                }
                HStack {
                    if km.checking { ProgressView().controlSize(.small) }
                    else if !km.latestTag.isEmpty {
                        Text("最新：\(km.latestTag)").font(.dsMono).foregroundColor(.secondary)
                    } else {
                        Text("点击检查可用内核版本").font(.dsBody).foregroundColor(.secondary)
                    }
                    Spacer()
                    HStack(spacing: 8) {
                        Button("检查更新") { Task { await km.check() } }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(km.checking)
                        if !km.assetURL.isEmpty {
                            Button {
                                Task {
                                    M.withEngineBusy {
                                        let wasTUN = M.tunOn
                                        await km.download()
                                        await M.reconnect()
                                        await M.reapplyTUN(wasOn: wasTUN)
                                    }
                                }
                            } label: {
                                if km.downloading { ProgressView().controlSize(.small) } else { Text("下载并切换") }
                            }
                            .controlSize(.small)
                            .buttonStyle(.borderedProminent)
                            .tint(DS.Palette.accent)
                            .disabled(km.downloading)
                        }
                    }
                    .frame(width: DS.Layout.fieldTrailing, alignment: .trailing)
                }
                Divider()
                HStack { Text("内核版本").font(.dsBody); Spacer() }
                // 内置内核(随 app 分发, 始终可切回)
                if km.hasBuiltin {
                    kernelRow(tag: "内置",
                              label: "内置内核" + (km.builtinVersion.isEmpty ? "" : " \(km.builtinVersion)"),
                              icon: "shippingbox.fill", km: km)
                }
                // 已下载的外部内核
                ForEach(km.installedTags, id: \.self) { tag in
                    kernelRow(tag: tag, label: tag, icon: "shippingbox", km: km)
                }
                if !km.note.isEmpty { Text(km.note).font(.dsBody).foregroundColor(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
                Text("下载源 MetaCubeX/mihomo releases。启用外部内核后引擎以监管进程模式运行；随时可切回内置内核。")
                    .font(.dsBody).foregroundColor(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear { km.scanInstalled(); km.detectBuiltin() }
    }

    /// One kernel row (built-in or downloaded) with activate / in-use state.
    @ViewBuilder
    private func kernelRow(tag: String, label: String, icon: String, km: KernelManager) -> some View {
        HStack {
            Image(systemName: icon).font(.dsBody).foregroundColor(tag == "内置" ? DS.Palette.accent : .secondary)
            Text(label).font(.dsMono)
            Spacer()
            if km.activeTag == tag {
                Label("使用中", systemImage: "checkmark.circle.fill")
                    .font(.dsBody).foregroundColor(DS.Palette.accent).frame(width: DS.Layout.fieldTrailing, alignment: .trailing)
            } else {
                Button("启用") {
                    M.withEngineBusy {
                        let wasTUN = M.tunOn
                        await km.activate(tag); try? await Task.sleep(nanoseconds: 3_500_000_000); await M.reconnect()
                        await M.reapplyTUN(wasOn: wasTUN)
                    }
                }
                    .buttonStyle(.bordered).controlSize(.small).frame(width: DS.Layout.fieldTrailing, alignment: .trailing)
            }
        }
        .padding(.vertical, 2)
    }
}

#Preview("Network 入站") {
    NetworkPage().environmentObject(AppModel.shared)
        .frame(width: 900, height: 720)
}
