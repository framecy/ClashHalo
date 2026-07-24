import SwiftUI

// MARK: - Network / TUN / Sniffer (read-only in stage A; editable in C/E)

private func cfgStr(_ c: [String: Any], _ k: String) -> String { c[k].map { "\($0)" } ?? "—" }
private func cfgBool(_ c: [String: Any], _ k: String) -> Bool { (c[k] as? Bool) == true }

struct NetworkPage: View {
    @EnvironmentObject var M: AppModel
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                // 内容栅格（design.md §9）：3 列 + gridGutter，跨列用 gridCellColumns。
                // 行 1 放三张短卡，行 2 的访问控制含 4 个列表行，跨满 3 列。
                Grid(alignment: .top,
                     horizontalSpacing: DS.Layout.gridGutter,
                     verticalSpacing: DS.Layout.gridGutter) {
                    GridRow {
                        Card(title: "入站端口", icon: "arrow.down.right.circle", stretch: true) {
                            VStack(spacing: 0) {
                                NumRow("HTTP 端口", key: "port", persistent: true)
                                NumRow("SOCKS 端口", key: "socks-port", persistent: true)
                                NumRow("混合端口", key: "mixed-port", persistent: true)
                                NumRow("Redir 端口", key: "redir-port", persistent: true)
                                NumRow("TProxy 端口", key: "tproxy-port", persistent: true)
                            }
                            Text("端口设为 0 即禁用。建议绝大多数应用使用混合端口（兼容 HTTP 与 SOCKS5）。")
                                .font(.dsCaption).foregroundColor(.secondary).padding(.top, DS.Spacing.m)
                        }
                        Card(title: "全局网络", icon: "globe", stretch: true) {
                            VStack(spacing: 0) {
                                ToggleRow("IPv6 支持", key: "ipv6", persistent: true)
                                ToggleRow("多路径 TCP (MPTCP)", key: "inbound-mptcp", persistent: true)
                                ToggleRow("TCP 并发连接", key: "tcp-concurrent", persistent: true)
                            }
                        }
                        Card(title: "局域网网关 (旁路由)", icon: "network.badge.shield.half.filled",
                             stretch: true) {
                            VStack(spacing: 0) {
                                DSFormRow(title: "作为网关中枢", monoKey: "gateway-mode") {
                                    HStack(spacing: DS.Spacing.s) {
                                        DSSwitch(isOn: Binding(get: { M.gatewayModeOn }, set: { _ in M.toggleGatewayMode() }),
                                                 disabled: M.engine.isBusy)
                                        if M.engine.isBusy {
                                            ProgressView().controlSize(.mini).scaleEffect(DS.Progress.miniScale)
                                        }
                                    }
                                }
                            }
                            Text("开启后将自动配置 IP 转发并接管局域网内其他所有设备的流量（需配合 TUN）。其他设备需将网关和 DNS 指向本机的局域网 IP。")
                                .font(.dsCaption).foregroundColor(.secondary).padding(.top, DS.Spacing.m)
                        }
                    }

                    GridRow {
                        Card(title: "访问控制", icon: "lock.shield") {
                            VStack(spacing: 0) {
                                ToggleRow("允许局域网连接", key: "allow-lan", persistent: true)
                                TextRow("绑定地址", key: "bind-address", placeholder: "*", persistent: true)
                                StringListRow("允许的 IP", key: "lan-allowed-ips", placeholder: "0.0.0.0/0", persistent: true)
                                StringListRow("拒绝的 IP", key: "lan-disallowed-ips", placeholder: "192.168.0.3/32", persistent: true)
                                StringListRow("代理认证", key: "authentication", placeholder: "user:pass", persistent: true)
                                StringListRow("免认证网段", key: "skip-auth-prefixes", placeholder: "127.0.0.1/8", persistent: true)
                            }
                            Text("开启“允许局域网”可将代理共享给同 Wi-Fi 下的其他设备；可用 IP 网段与认证做严格审查。")
                                .font(.dsCaption).foregroundColor(.secondary).padding(.top, DS.Spacing.m)
                        }
                        .gridCellColumns(3)
                    }

                    if M.gatewayModeOn {
                        GridRow {
                            GatewayDevicesView().gridCellColumns(3)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DS.Layout.pageContentInset)
                .padding(.bottom, 26)
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
                VStack(spacing: DS.Spacing.s) {
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
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text(dev.ip)
                    .font(.dsMonoBold)
                HStack(spacing: DS.Spacing.m) {
                    Label("\(dev.activeConnections) 连接", systemImage: "point.3.connected.trianglepath.dotted")
                    Label("\(dev.durationString)", systemImage: "clock")
                }
                .font(.dsCaption)
                .foregroundColor(.secondary)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: DS.Spacing.xs) {
                HStack(spacing: DS.Spacing.xs) {
                    Image(systemName: "arrow.up")
                    Text(fmtRate(Double(dev.uploadRate)))
                        .frame(width: 72, alignment: .trailing)
                    Text(fmtBytes(Double(dev.totalUpload)))
                        .frame(width: 72, alignment: .trailing)
                }
                .foregroundColor(DS.Palette.ok)
                HStack(spacing: DS.Spacing.xs) {
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
        .padding(DS.Spacing.m)
        .background(DS.Palette.fillFaint)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
    }
}

struct TunPage: View {
    @EnvironmentObject var M: AppModel
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                // 3 列栅格：网卡本体跨 2 列（原型 `2fr 1fr` 的宽卡位），
                // 路由 / DNS 劫持占 1 列。
                Grid(alignment: .top,
                     horizontalSpacing: DS.Layout.gridGutter,
                     verticalSpacing: DS.Layout.gridGutter) {
                    GridRow {
                        Card(title: "TUN 虚拟网卡", icon: "shield.lefthalf.filled", stretch: true) {
                            VStack(spacing: 0) {
                                DSFormRow(title: "启用 TUN", monoKey: "tun.enable") {
                                    HStack(spacing: DS.Spacing.s) {
                                        DSSwitch(isOn: Binding(get: { M.tunOn }, set: { _ in M.toggleTUN() }),
                                                 disabled: M.engine.isBusy)
                                        if M.engine.isBusy {
                                            ProgressView().controlSize(.mini).scaleEffect(DS.Progress.miniScale)
                                        }
                                    }
                                }
                                NPicker("协议栈", "tun", "stack", [("gvisor","gVisor"),("system","System"),("mixed","Mixed")])
                                NToggle("自动路由", "tun", "auto-route")
                                NToggle("自动检测网卡", "tun", "auto-detect-interface")
                            }
                            Text("用户态 UTUN (AF_SYSTEM)，不占 VPN 插槽。")
                                .font(.dsCaption).foregroundColor(.secondary).padding(.top, DS.Spacing.m)
                        }
                        .gridCellColumns(2)

                        Card(title: "路由与 DNS 劫持", icon: "arrow.triangle.branch", stretch: true) {
                            VStack(spacing: 0) {
                                NList("DNS 劫持", "tun", "dns-hijack", placeholder: "any:53")
                                NList("路由排除网段", "tun", "route-exclude-address", placeholder: "192.168.0.0/16")
                            }
                            Text("在「SD-WAN」中排除虚拟网段，可避免抢占其它隧道的路由。")
                                .font(.dsCaption).foregroundColor(.secondary).padding(.top, DS.Spacing.m)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DS.Layout.pageContentInset)
                .padding(.bottom, 26)
            }
        }
    }
}

struct SnifferPage: View {
    @EnvironmentObject var M: AppModel
    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                // 只有一张卡：跨 2 列，第 3 列用透明占位撑住列宽，
                // 这样它的宽度与其它 tab 的宽卡一致，而不是拉满整行。
                Grid(alignment: .top,
                     horizontalSpacing: DS.Layout.gridGutter,
                     verticalSpacing: DS.Layout.gridGutter) {
                    GridRow {
                        Card(title: "协议嗅探 Sniffer", icon: "scope") {
                            VStack(spacing: 0) {
                                NToggle("启用嗅探", "sniffer", "enable")
                                NToggle("覆盖目标地址", "sniffer", "override-destination")
                                NToggle("强制 DNS 映射", "sniffer", "force-dns-mapping")
                                NToggle("解析纯 IP", "sniffer", "parse-pure-ip")
                            }
                            Text("从 TLS / QUIC / HTTP 握手中提取真实域名用于分流，对走 IP 的连接尤为重要。默认嗅探协议：TLS(443,8443), HTTP(80,8080-8880), QUIC(443,8443)。修改后请重启核心生效。")
                                .font(.dsCaption).foregroundColor(.secondary).padding(.top, DS.Spacing.m)
                        }
                        .gridCellColumns(2)

                        Color.clear.frame(height: 1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DS.Layout.pageContentInset)
                .padding(.bottom, 26)
            }
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
    // outline only (design.md §6.8) — no .fill variants
    private let tabs: [(String, String, String)] = [
        ("入站", "network", "arrow.down.right.circle"),
        ("TUN", "tun", "shield"),
        ("DNS", "dns", "network"),
        ("嗅探", "sniffer", "scope"),
        ("内核", "kernel", "cpu")
    ]


    var body: some View {
        VStack(spacing: 0) {
            PageHead(title: "网络") {
                if tab == "dns" {
                    Button { M.flushDnsCache() } label: { Label("刷新缓存", systemImage: "arrow.clockwise") }
                        .dsButton()
                    Button { M.clearAllCache() } label: { Label("清空", systemImage: "trash") }
                        .dsButton()
                }
            }

            // 分区切换 — 原型 Seg 语言，位于标题行下方独立一行
            HStack {
                DSSegmentedControl(selection: $tab, choices: tabs.map {
                    DSChoice($0.0, $0.1, systemImage: $0.2)
                })
                .frame(maxWidth: 480)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DS.Layout.pageContentInset)
            .padding(.bottom, DS.Spacing.m)

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


}

// MARK: - Reusable config form rows (read M.configs, write via M.patch)

/// 列表项 chip — StringListRow / NList 共用：mono 文本 + 移除按钮。
@ViewBuilder
func listChip(_ text: String, remove: @escaping () -> Void) -> some View {
    HStack {
        Text(text).font(.dsMonoSm).foregroundColor(.secondary)
        Spacer(minLength: DS.Spacing.s)
        Button(action: remove) { Image(systemName: "minus.circle").font(.dsBody) }
            .buttonStyle(.borderless)
    }
    .padding(.horizontal, DS.Spacing.s)
    .padding(.vertical, DS.Spacing.xs)
    .frame(maxWidth: 360, alignment: .leading)
    .background(DS.Shape.control().fill(DS.Palette.cardHeadBg))
    .overlay(DS.Shape.control().strokeBorder(DS.Palette.border, lineWidth: 0.5))
}

/// Number field bound to a top-level config key.
struct NumRow: View {
    @EnvironmentObject var M: AppModel
    let label: String; let key: String; let persistent: Bool
    init(_ label: String, key: String, persistent: Bool = false) { self.label = label; self.key = key; self.persistent = persistent }
    @State private var text = ""
    @State private var hasChanges = false
    @FocusState private var isFocused: Bool

    var body: some View {
        DSFormRow(title: label, monoKey: key) {
            HStack(spacing: DS.Spacing.s) {
                TextField("0", text: $text)
                    .inputStyle()
                    .font(.dsMonoSm)
                    .frame(width: 110)
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
                        .dsButton(.prominent)
                }
            }
        }
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
        DSFormRow(title: label, monoKey: key) {
            DSSwitch(isOn: Binding(
                get: { (M.configs[key] as? Bool) == true },
                set: { v in Task { if persistent { await M.patchPersistent([key: v]) } else { await M.patch([key: v]) } } }
            ))
        }
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
        DSFormRow(title: label, monoKey: key) {
            HStack(spacing: DS.Spacing.s) {
                TextField(placeholder, text: $text)
                    .inputStyle()
                    .font(.dsMonoSm)
                    .frame(maxWidth: 280)
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
                        .dsButton(.prominent)
                }
            }
        }
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
        DSFormRow(title: label, monoKey: key) {
            DSMenuPicker(selection: Binding<String>(
                get: {
                    let val = (M.configs[key] as? String) ?? ""
                    return options.contains(where: { $0.0 == val }) ? val : (options.first?.0 ?? "")
                },
                set: { v in Task { if persistent { await M.patchPersistent([key: v]) } else { await M.patch([key: v]) } } }
            ), choices: options.map { DSChoice($0.1, $0.0) })
            .frame(width: 160)
        }
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
        DSFormRow(title: label, monoKey: key, stacked: true) {
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                // Existing entries — each a chip on a subtle fill so the list reads as
                // distinct rows, clearly separated from the add field below.
                if !items.isEmpty {
                    VStack(spacing: DS.Spacing.xs) {
                        ForEach(items.indices, id: \.self) { i in
                            listChip(items[i]) { items.remove(at: i); commit() }
                        }
                    }
                }
                // Add row — visually the input affordance, set apart from the list above.
                HStack(spacing: DS.Spacing.s) {
                    TextField(placeholder, text: $draft)
                        .inputStyle()
                        .font(.dsMonoSm)
                        .frame(maxWidth: 360)
                        .overlay(DS.Shape.control().strokeBorder(!draftValid ? DS.Palette.error.opacity(0.7) : Color.clear, lineWidth: 1))
                    Button { if !draft.isEmpty && draftValid { items.append(draft); draft = ""; commit() } } label: { Image(systemName: "plus.circle.fill") }
                        .buttonStyle(.borderless).disabled(!draftValid || draft.isEmpty)
                }
                if !draftValid {
                    Text("格式无效 — 请检查输入（如 IP/CIDR: 10.0.0.0/8, URL: https://...）")
                        .font(.dsCaption).foregroundColor(DS.Palette.error)
                }
            }
        }
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
        DSFormRow(title: label, monoKey: "geox-url.\(sub)") {
            TextField("https://…", text: $text)
                .inputStyle()
                .font(.dsMonoSm)
                .onSubmit {
                    let geo = (M.configs["geox-url"] as? [String: Any] ?? [:])
                        .merging([sub: text]) { _, new in new }
                    Task { await M.patchPersistent(["geox-url": geo]) }
                }
        }
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
        DSFormRow(title: label, monoKey: "\(parent).\(sub)") {
            DSSwitch(isOn: Binding(
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
        }
    }
}

struct NPicker: View {
    @EnvironmentObject var M: AppModel
    let parent: String; let sub: String; let label: String; let options: [(String, String)]; let persistent: Bool
    init(_ label: String, _ parent: String, _ sub: String, _ options: [(String, String)], persistent: Bool = true) {
        self.label = label; self.parent = parent; self.sub = sub; self.options = options; self.persistent = persistent
    }
    var body: some View {
        DSFormRow(title: label, monoKey: "\(parent).\(sub)") {
            DSMenuPicker(selection: Binding<String>(
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
            ), choices: options.map { DSChoice($0.1, $0.0) })
            .frame(width: 160)
        }
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
        DSFormRow(title: label, monoKey: "\(parent).\(sub)") {
            TextField(placeholder, text: $text)
                .inputStyle()
                .font(.dsMonoSm)
                .onSubmit {
                    Task {
                        if persistent {
                            await M.patchPersistent([parent: [sub: text]])
                        } else {
                            await M.patch([parent: [sub: text]])
                        }
                    }
                }
                .frame(maxWidth: 280)
        }
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
        DSFormRow(title: label, monoKey: "\(parent).\(sub)", stacked: true) {
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                if !items.isEmpty {
                    VStack(spacing: DS.Spacing.xs) {
                        ForEach(items.indices, id: \.self) { i in
                            listChip(items[i]) { items.remove(at: i); commit() }
                        }
                    }
                }
                HStack(spacing: DS.Spacing.s) {
                    TextField(placeholder, text: $draft)
                        .inputStyle()
                        .font(.dsMonoSm)
                        .frame(maxWidth: 360)
                    Button { if !draft.isEmpty { items.append(draft); draft = ""; commit() } } label: { Image(systemName: "plus.circle.fill") }.buttonStyle(.borderless)
                }
            }
        }
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
                        VStack(spacing: 0) {
                            TextRow("API 监听地址", key: "external-controller", placeholder: "127.0.0.1:9090", persistent: true)
                            TextRow("API 密钥 (Secret)", key: "secret", placeholder: "留空即无密码", persistent: true)
                            TextRow("本地面板目录", key: "external-ui", placeholder: "zashboard", persistent: true)
                            TextRow("面板解压目录名", key: "external-ui-name", placeholder: "zashboard", persistent: true)
                            TextRow("面板下载地址", key: "external-ui-url", placeholder: "https://github.com/Zephyruso/zashboard/releases/latest/download/dist-no-fonts.zip", persistent: true)
                        }
                        Text("内核内置面板 (如 Zashboard)。配置下载地址后，内核启动时会自动下载并解压到指定目录，您可通过 http://<API地址>/ui 访问。")
                            .font(.dsCaption).foregroundColor(.secondary).padding(.top, DS.Spacing.m)
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
            }
            .padding(.horizontal, DS.Layout.pageContentInset)
            .padding(.bottom, 26)
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
                    let connecting = M.engine.isBusy && !M.reachable
                    Circle()
                        .fill(M.reachable ? DS.Palette.ok : (connecting ? DS.Palette.warn : DS.Palette.error))
                        .frame(width: 8, height: 8)
                    Text(M.reachable ? "运行中 · mihomo \(M.version)"
                                     : (connecting ? "启动中…" : "未运行 · 开启代理或 TUN 将自动启动"))
                        .font(.dsBody).foregroundColor(.secondary)
                    Spacer()
                    if M.reachable {
                        Button("重启内核", systemImage: "arrow.triangle.2.circlepath") {
                            M.withEngineBusy {
                                let wasTUN = M.tunOn
                                let wasProxy = M.systemProxyOn
                                let port = M.proxyPort
                                // Temporarily clear system proxy so a dead kernel
                                // can't black-hole the Mac during restart.
                                if wasProxy {
                                    _ = await M.engine.setSystemProxy(enabled: false, port: port)
                                    M.systemProxyOn = false
                                }
                                // Only take root back if the current mode actually
                                // needs it — a proxy-only session stays user-mode.
                                await M.engine.restart(preferRoot: wasTUN || M.gatewayModeOn)
                                let ready = await M.waitForKernelReady(maxAttempts: 10)
                                await M.reconnect()
                                if ready {
                                    await M.reapplyTUN(wasOn: wasTUN)
                                    if wasProxy {
                                        _ = await M.engine.setSystemProxy(enabled: true, port: port)
                                        M.systemProxyOn = true
                                    }
                                    M.showToast("内核已重启", kind: .ok)
                                } else {
                                    M.showToast("内核重启超时，系统代理未恢复", kind: .warn)
                                }
                            }
                        }.dsButton(.warning)
                    }
                }
                Divider()
                HStack {
                    Text("更新通道").font(.dsBody)
                    Spacer()
                    DSSegmentedControl(selection: $km.channel, choices: [
                        DSChoice("正式版", "stable"),
                        DSChoice("Alpha", "alpha")
                    ])
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
                        Button("检查更新") {
                            Task { await km.check() }
                        }
                            .dsButton()
                            .disabled(km.checking || km.downloading)
                        if !km.assetURL.isEmpty {
                            Button {
                                // Download while kernel still serves traffic (no isBusy).
                                // Only the final swap/restart holds the engine busy lock.
                                Task {
                                    let wasTUN = M.tunOn
                                    let switched = await km.download()
                                    if switched {
                                        // activate already waited for readiness + restored proxy
                                        await M.reconnect()
                                        if M.reachable {
                                            await M.reapplyTUN(wasOn: wasTUN)
                                        }
                                        M.showToast(km.note.isEmpty ? "内核已更新" : km.note, kind: .ok)
                                    } else {
                                        await M.reconnect()
                                        M.showToast(km.note.isEmpty ? "内核更新失败" : km.note, kind: .error)
                                    }
                                }
                            } label: {
                                if km.downloading {
                                    HStack(spacing: 6) {
                                        ProgressView().controlSize(.small)
                                        Text(km.progress > 0 ? String(format: "%.0f%%", km.progress * 100) : "…")
                                            .font(.dsMono)
                                    }
                                } else {
                                    Text("下载并切换")
                                }
                            }
                            .dsButton(.prominent)
                            .disabled(km.downloading || km.checking || M.engine.isBusy)
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
        .onAppear {
            km.scanInstalled()
            km.detectBuiltin()
            Task { await km.refreshRunningVersion() }
        }
    }

    /// One kernel row (built-in or downloaded) with activate / in-use state.
    @ViewBuilder
    private func kernelRow(tag: String, label: String, icon: String, km: KernelManager) -> some View {
        // "使用中" only when activeTag matches AND bin version matches the slot
        // (isSlotInUse). Otherwise show 启用 — covers "downloaded but not activated".
        let inUse = km.isSlotInUse(tag)
        let showReactivate = !inUse && tag == "正式版" && km.stableNeedsActivate
        return HStack {
            Image(systemName: icon).font(.dsBody).foregroundColor(tag == "内置" ? DS.Palette.accent : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.dsMono)
                if showReactivate, !km.installedStableTag.isEmpty, !km.runningVersion.isEmpty {
                    Text("已下载 \(km.installedStableTag) · 运行中 \(km.runningVersion)")
                        .font(.dsBody)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            if inUse {
                Label("使用中", systemImage: "checkmark.circle.fill")
                    .font(.dsBody).foregroundColor(DS.Palette.accent).frame(width: DS.Layout.fieldTrailing, alignment: .trailing)
            } else {
                Button(showReactivate ? "启用已下载" : "启用") {
                    M.withEngineBusy {
                        let wasTUN = M.tunOn
                        let ok = await km.activate(tag)
                        await M.reconnect()
                        if ok {
                            await M.reapplyTUN(wasOn: wasTUN)
                            M.showToast("已启用 \(tag)", kind: .ok)
                        } else {
                            M.showToast(km.note.isEmpty ? "启用 \(tag) 失败" : km.note, kind: .error)
                        }
                    }
                }
                    .dsButton(showReactivate ? .prominent : .secondary)
                    .disabled(M.engine.isBusy)
                    .frame(width: DS.Layout.fieldTrailing, alignment: .trailing)
            }
        }
        .padding(.vertical, 2)
    }
}

#Preview("Network 入站") {
    NetworkPage().environmentObject(AppModel.shared)
        .frame(width: 900, height: 720)
}
