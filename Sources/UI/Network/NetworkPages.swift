import SwiftUI

// MARK: - Network / TUN / Sniffer (read-only in stage A; editable in C/E)

private func cfgStr(_ c: [String: Any], _ k: String) -> String { c[k].map { "\($0)" } ?? "—" }
private func cfgBool(_ c: [String: Any], _ k: String) -> Bool { (c[k] as? Bool) == true }

struct NetworkPage: View {
    @EnvironmentObject var M: AppModel
    var body: some View {
        VStack(spacing: 0) {
            PageHead(title: "网络入站", desc: "端口监听 · 局域网共享 · 访问控制列表 (ACL)")

            ScrollView {
                VStack(spacing: DS.Spacing.l) {
                    Card(title: "入站端口", icon: "arrow.down.right.circle") {
                        VStack(spacing: 2) {
                            NumRow("HTTP 端口", key: "port")
                            NumRow("SOCKS 端口", key: "socks-port")
                            NumRow("混合端口", key: "mixed-port")
                            NumRow("Redir 端口", key: "redir-port")
                            NumRow("TProxy 端口", key: "tproxy-port")
                        }
                        Text("端口设为 0 即禁用。建议绝大多数应用使用混合端口（兼容 HTTP 与 SOCKS5）。")
                            .font(.dsBody).foregroundColor(.secondary).padding(.top, 6)
                    }
                    Card(title: "全局网络", icon: "globe") {
                        VStack(spacing: 2) {
                            ToggleRow("IPv6 支持", key: "ipv6")
                            ToggleRow("多路径 TCP (MPTCP)", key: "inbound-mptcp")
                            ToggleRow("TCP 并发连接", key: "tcp-concurrent")
                        }
                    }
                    Card(title: "访问控制", icon: "lock.shield") {
                        VStack(spacing: 2) {
                            ToggleRow("允许局域网连接", key: "allow-lan")
                            TextRow("绑定地址", key: "bind-address", placeholder: "*")
                            StringListRow("允许的 IP", key: "lan-allowed-ips", placeholder: "0.0.0.0/0")
                            StringListRow("拒绝的 IP", key: "lan-disallowed-ips", placeholder: "192.168.0.3/32")
                            StringListRow("代理认证", key: "authentication", placeholder: "user:pass")
                            StringListRow("免认证网段", key: "skip-auth-prefixes", placeholder: "127.0.0.1/8")
                        }
                        Text("开启“允许局域网”可将代理共享给同 Wi-Fi 下的其他设备；可用 IP 网段与认证做严格审查。")
                            .font(.dsBody).foregroundColor(.secondary).padding(.top, 6)
                    }
                    Spacer(minLength: 0)
                }.padding(DS.Spacing.xl)
            }
        }
    }
}

struct TunPage: View {
    @EnvironmentObject var M: AppModel
    var body: some View {
        VStack(spacing: 0) {
            PageHead(title: "TUN 模式", desc: "虚拟网卡驱动 · 协议栈选择 · 路由注入策略")

            ScrollView {
                VStack(spacing: DS.Spacing.l) {
                    Card(title: "TUN 虚拟网卡", icon: "shield.lefthalf.filled") {
                    VStack(spacing: 2) {
                        HStack {
                            Text("启用 TUN").font(.dsBody); Spacer()
                            Toggle("", isOn: Binding(get: { M.tunOn }, set: { _ in M.toggleTUN() }))
                                .toggleStyle(.switch).labelsHidden()
                        }.padding(.vertical, 5)
                        NPicker("协议栈", "tun", "stack", [("gvisor","gVisor"),("system","System"),("mixed","Mixed")])
                        NToggle("自动路由", "tun", "auto-route")
                        NToggle("自动检测网卡", "tun", "auto-detect-interface")
                        NList("DNS 劫持", "tun", "dns-hijack", placeholder: "any:53")
                        NList("路由排除网段", "tun", "route-exclude-address", placeholder: "192.168.0.0/16")
                    }
                    Text("用户态 UTUN (AF_SYSTEM)，不占 VPN 插槽。排除 SD-WAN 网段可避免抢占其路由。")
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
            PageHead(title: "流量嗅探", desc: "协议解析 (TLS/HTTP/QUIC) · 真实域名还原")

            ScrollView {
                VStack(spacing: DS.Spacing.l) {
                    Card(title: "协议嗅探 Sniffer", icon: "scope") {
                    VStack(spacing: 2) {
                        NToggle("启用嗅探", "sniffer", "enable")
                        NToggle("覆盖目标地址", "sniffer", "override-destination")
                        NToggle("强制 DNS 映射", "sniffer", "force-dns-mapping")
                    }
                    Text("从 TLS / QUIC / HTTP 握手中提取真实域名用于分流，对走 IP 的连接尤为重要。")
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

// MARK: - Reusable config form rows (read M.configs, write via M.patch)

/// Number field bound to a top-level config key.
struct NumRow: View {
    @EnvironmentObject var M: AppModel
    let label: String; let key: String
    init(_ label: String, key: String) { self.label = label; self.key = key }
    @State private var text = ""
    var body: some View {
        HStack {
            Text(label).font(.dsBody)
            Spacer()
            TextField("0", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.dsMono)
                .multilineTextAlignment(.trailing)
                .frame(width: 90)
                .onSubmit { commit() }
                .frame(width: 160, alignment: .trailing)
        }
        .padding(.vertical, 5)
        .onAppear { text = intStr(M.configs[key]) }
        .onChange(of: configValue) { text = intStr(M.configs[key]) }
    }
    private var configValue: String { intStr(M.configs[key]) }
    private func intStr(_ v: Any?) -> String { if let i = v as? Int { return "\(i)" }; if let d = v as? Double { return "\(Int(d))" }; return "0" }
    private func commit() {
        let n = Int(text) ?? 0
        Task { await M.patch([key: n]) }
    }
}

/// Toggle bound to a top-level boolean config key.
struct ToggleRow: View {
    @EnvironmentObject var M: AppModel
    let label: String; let key: String
    init(_ label: String, key: String) { self.label = label; self.key = key }
    var body: some View {
        HStack {
            Text(label).font(.dsBody)
            Spacer()
            Toggle("", isOn: Binding(
                get: { (M.configs[key] as? Bool) == true },
                set: { v in Task { await M.patch([key: v]) } }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .frame(width: 160, alignment: .trailing)
        }
        .padding(.vertical, 5)
    }
}

/// Single-string field bound to a top-level config key.
struct TextRow: View {
    @EnvironmentObject var M: AppModel
    let label: String; let key: String; let placeholder: String
    init(_ label: String, key: String, placeholder: String = "") { self.label = label; self.key = key; self.placeholder = placeholder }
    @State private var text = ""
    var body: some View {
        HStack {
            Text(label).font(.dsBody)
            Spacer()
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.dsMono)
                .multilineTextAlignment(.trailing)
                .onSubmit { Task { await M.patch([key: text]) } }
                .frame(width: 160, alignment: .trailing)
        }
        .padding(.vertical, 5)
        .onAppear { text = (M.configs[key] as? String) ?? "" }
    }
}

/// Picker bound to a top-level string config key.
struct PickerRow: View {
    @EnvironmentObject var M: AppModel
    let label: String; let key: String; let options: [(String, String)]
    init(_ label: String, key: String, options: [(String, String)]) { self.label = label; self.key = key; self.options = options }
    var body: some View {
        HStack {
            Text(label).font(.dsBody)
            Spacer()
            Picker("", selection: Binding<String>(
                get: {
                    let val = (M.configs[key] as? String) ?? ""
                    return options.contains(where: { $0.0 == val }) ? val : (options.first?.0 ?? "")
                },
                set: { v in Task { await M.patch([key: v]) } }
            )) {
                ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
            }
            .labelsHidden()
            .frame(width: 160, alignment: .trailing)
        }
        .padding(.vertical, 5)
    }
}

/// Editable string-list bound to a top-level array config key.
/// Automatically validates input format based on placeholder hints (CIDR, URL, etc.).
struct StringListRow: View {
    @EnvironmentObject var M: AppModel
    let label: String; let key: String; let placeholder: String
    init(_ label: String, key: String, placeholder: String = "") { self.label = label; self.key = key; self.placeholder = placeholder }
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
                        .background(RoundedRectangle(cornerRadius: DS.Radius.control).fill(DS.Palette.hairline))
                    }
                }
            }
            // Add row — visually the input affordance, set apart from the list above.
            HStack(spacing: DS.Spacing.s) {
                TextField(placeholder, text: $draft)
                    .textFieldStyle(.roundedBorder).font(.dsMono)
                    .overlay(RoundedRectangle(cornerRadius: DS.Radius.control).stroke(!draftValid ? DS.Palette.error.opacity(0.7) : Color.clear, lineWidth: 1))
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
    private func commit() { Task { await M.patch([key: items]) } }

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
                .textFieldStyle(.roundedBorder).font(.dsMono)
                .onSubmit { Task { await M.patch(["geox-url": [sub: text]]) } }
        }
        .padding(.vertical, 5)
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
    let parent: String; let sub: String; let label: String
    init(_ label: String, _ parent: String, _ sub: String) { self.label = label; self.parent = parent; self.sub = sub }
    var body: some View {
        HStack {
            Text(label).font(.dsBody); Spacer()
            Toggle("", isOn: Binding(
                get: { (nestedDict(M, parent)[sub] as? Bool) == true },
                set: { v in Task { await M.patch([parent: [sub: v]]) } }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .frame(width: 160, alignment: .trailing)
        }.padding(.vertical, 5)
    }
}

struct NPicker: View {
    @EnvironmentObject var M: AppModel
    let parent: String; let sub: String; let label: String; let options: [(String, String)]
    init(_ label: String, _ parent: String, _ sub: String, _ options: [(String, String)]) {
        self.label = label; self.parent = parent; self.sub = sub; self.options = options
    }
    var body: some View {
        HStack {
            Text(label).font(.dsBody); Spacer()
            Picker("", selection: Binding<String>(
                get: {
                    let val = (nestedDict(M, parent)[sub] as? String) ?? ""
                    return options.contains(where: { $0.0 == val }) ? val : (options.first?.0 ?? "")
                },
                set: { v in Task { await M.patch([parent: [sub: v]]) } }
            )) { ForEach(options, id: \.0) { Text($0.1).tag($0.0) } }
            .labelsHidden()
            .frame(width: 160, alignment: .trailing)
        }.padding(.vertical, 5)
    }
}

struct NText: View {
    @EnvironmentObject var M: AppModel
    let parent: String; let sub: String; let label: String; let placeholder: String
    init(_ label: String, _ parent: String, _ sub: String, placeholder: String = "") {
        self.label = label; self.parent = parent; self.sub = sub; self.placeholder = placeholder
    }
    @State private var text = ""
    var body: some View {
        HStack {
            Text(label).font(.dsBody); Spacer()
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.dsMono)
                .multilineTextAlignment(.trailing)
                .onSubmit { Task { await M.patch([parent: [sub: text]]) } }
                .frame(width: 160, alignment: .trailing)
        }.padding(.vertical, 5)
        .onAppear { text = (nestedDict(M, parent)[sub] as? String) ?? "" }
    }
}

struct NList: View {
    @EnvironmentObject var M: AppModel
    let parent: String; let sub: String; let label: String; let placeholder: String
    init(_ label: String, _ parent: String, _ sub: String, placeholder: String = "") {
        self.label = label; self.parent = parent; self.sub = sub; self.placeholder = placeholder
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
                        .background(RoundedRectangle(cornerRadius: DS.Radius.control).fill(DS.Palette.hairline))
                    }
                }
            }
            HStack(spacing: DS.Spacing.s) {
                TextField(placeholder, text: $draft).textFieldStyle(.roundedBorder).font(.dsMono)
                Button { if !draft.isEmpty { items.append(draft); draft = ""; commit() } } label: { Image(systemName: "plus.circle.fill") }.buttonStyle(.borderless)
            }
        }.padding(.vertical, DS.Spacing.s)
        .onAppear { items = (nestedDict(M, parent)[sub] as? [Any])?.map { "\($0)" } ?? [] }
    }
    private func commit() { Task { await M.patch([parent: [sub: items]]) } }
}

// MARK: - Kernel Management Page

struct KernelMgmtPage: View {
    @EnvironmentObject var M: AppModel
    var body: some View {
        VStack(spacing: 0) {
            PageHead(title: "内核管理", desc: "版本更新 · 核心状态 · 启动日志")

            ScrollView {
                VStack(spacing: DS.Spacing.l) {
                    KernelCard()
                    
                    Card(title: "启动日志", icon: "terminal") {
                        VStack(alignment: .leading, spacing: 4) {
                            if M.kernelLogs.isEmpty {
                                Text("暂无启动日志").font(.dsBody).foregroundColor(.secondary)
                            } else {
                                ForEach(M.kernelLogs.indices, id: \.self) { i in
                                    Text(M.kernelLogs[i])
                                        .font(.dsMono)
                                        .foregroundColor(M.kernelLogs[i].contains("错误") ? .red : .primary)
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
                    Circle().fill(M.reachable ? Color.green : Color.red).frame(width: 8, height: 8)
                    Text(M.reachable ? "运行中 · mihomo \(M.version)" : "未连接").font(.dsBody).foregroundColor(.secondary)
                    Spacer()
                    if M.reachable {
                        Button("重启内核", systemImage: "arrow.triangle.2.circlepath") {
                            guard !M.engine.isBusy else { M.showToast("内核操作进行中，请稍候…"); return }
                            M.engine.isBusy = true
                            Task {
                                defer { M.engine.isBusy = false }
                                await M.engine.restart(); try? await Task.sleep(nanoseconds: 3_000_000_000); await M.reconnect(); M.showToast("内核已重启")
                            }
                        }.buttonStyle(.bordered).tint(.orange).controlSize(.small)
                    }
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
                    .frame(width: 160, alignment: .trailing)
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
                                Task { await km.download() }
                            } label: {
                                if km.downloading { ProgressView().controlSize(.small) } else { Text("下载 \(km.channel == "alpha" ? "Alpha" : "正式版")") }
                            }
                            .controlSize(.small)
                            .buttonStyle(.borderedProminent)
                            .tint(M.accent)
                            .disabled(km.downloading)
                        }
                    }
                    .frame(width: 160, alignment: .trailing)
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
            Image(systemName: icon).font(.dsBody).foregroundColor(tag == "内置" ? M.accent : .secondary)
            Text(label).font(.dsMono)
            Spacer()
            if km.activeTag == tag {
                Label("使用中", systemImage: "checkmark.circle.fill")
                    .font(.dsBody).foregroundColor(M.accent).frame(width: 160, alignment: .trailing)
            } else {
                Button("启用") {
                    guard !M.engine.isBusy else { M.showToast("内核操作进行中，请稍候…"); return }
                    M.engine.isBusy = true
                    Task {
                        defer { M.engine.isBusy = false }
                        await km.activate(tag); try? await Task.sleep(nanoseconds: 3_500_000_000); await M.reconnect()
                    }
                }
                    .buttonStyle(.bordered).controlSize(.small).frame(width: 160, alignment: .trailing)
            }
        }
        .padding(.vertical, 2)
    }
}
