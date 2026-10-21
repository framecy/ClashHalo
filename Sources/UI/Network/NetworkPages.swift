import SwiftUI

// MARK: - Network / TUN / Sniffer (read-only in stage A; editable in C/E)

private func cfgStr(_ c: [String: Any], _ k: String) -> String { c[k].map { "\($0)" } ?? "—" }
private func cfgBool(_ c: [String: Any], _ k: String) -> Bool { (c[k] as? Bool) == true }

// MARK: - 端口转发（入站监听）
//
// 数据与写盘都走 `InboundListener` / `InboundListenerStore`（纯逻辑 + 回归套件），
// 这里只做表单与列表。两条安全线：
//   * 默认 `listen: 127.0.0.1`（仅本机），「允许局域网访问」必须显式勾选；
//   * 端口冲突在保存前就查清楚并指出是谁占的，不把内核的 500 抛给用户。

struct PortForwardingCard: View {
    @EnvironmentObject var M: AppModel
    @State private var editing: InboundListener? = nil
    @State private var showingNew = false
    @State private var confirmingDelete: InboundListener? = nil
    /// 缓存的解析结果。`body` 里同步读 70 KB 的 config.yaml 会随每次重绘发生，
    /// 规则页也是同样的做法：只在文件路径变化或 `configContentEpoch` 自增时重读。
    @State private var listeners: [InboundListener] = []

    var body: some View {
        let list = listeners
        return Card(title: "端口转发（入站监听）", icon: "arrow.left.arrow.right",
                    actions: {
                        Button { showingNew = true } label: { Label("添加转发", systemImage: "plus") }
                            .dsButton()
                            .disabled(M.engine.isBusy)
                    }) {
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                if list.isEmpty {
                    Text("把本机端口转发到局域网里的设备（如 NAS 管理页、打印机后台）。默认只监听 127.0.0.1，不会对外开放。")
                        .font(.dsBody).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(list) { l in row(l) }
                }
                if !list.isEmpty {
                    Text("监听在 0.0.0.0 的转发对同网段所有设备开放；不需要时请关掉。")
                        .font(.dsCaption).foregroundColor(.secondary)
                        .padding(.top, DS.Spacing.xs)
                }
            }
        }
        .onAppear(perform: reloadListeners)
        .onChange(of: M.engine.configFilePath) { _, _ in reloadListeners() }
        .onChange(of: M.configContentEpoch) { _, _ in reloadListeners() }
        .sheet(isPresented: $showingNew) {
            ListenerEditorSheet(existing: listeners, editing: nil) { showingNew = false }
        }
        .sheet(item: Binding(get: { editing.map { ListenerBox(listener: $0) } },
                             set: { editing = $0?.listener })) { box in
            ListenerEditorSheet(existing: listeners, editing: box.listener) { editing = nil }
        }
        .confirmationDialog("删除转发「\(confirmingDelete?.name ?? "")」？",
                            isPresented: Binding(get: { confirmingDelete != nil },
                                                 set: { if !$0 { confirmingDelete = nil } }),
                            titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                guard let target = confirmingDelete else { return }
                confirmingDelete = nil
                M.saveInboundListeners(listeners.filter { $0.name != target.name })
            }
        } message: {
            Text("将移除该监听端口并立即重载内核；正在使用这个转发的连接会断开。")
        }
    }

    struct ListenerBox: Identifiable {
        let listener: InboundListener
        var id: String { listener.id }
    }

    private func row(_ l: InboundListener) -> some View {
        HStack(spacing: DS.Spacing.m) {
            DSCompactSwitch(isOn: l.isEnabled,
                            isEnabled: !M.engine.isBusy,
                            accessibilityText: l.name) {
                toggle(l, !l.isEnabled)
            }

            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                HStack(spacing: DS.Spacing.s) {
                    Text(l.name).font(.dsBodySemibold)
                    Text(l.type.label)
                        .font(.dsCaption)
                        .foregroundColor(.secondary)
                    Text(l.allowsLAN ? "局域网可访问" : "仅本机")
                        .font(.dsCaption)
                        .foregroundColor(l.allowsLAN ? DS.Palette.warn : .secondary)
                }
                HStack(spacing: DS.Spacing.m) {
                    Text("127.0.0.1:\(l.port)").font(.dsMono)
                    if l.type.needsTarget {
                        Text("→ \(l.target)").font(.dsMono).foregroundColor(.secondary)
                    }
                    Text(l.networkText.uppercased()).font(.dsCaption).foregroundColor(.secondary)
                }
                .font(.dsCaption)
            }
            Spacer(minLength: 0)

            Button { editing = l } label: { Image(systemName: "pencil") }
                .buttonStyle(.borderless).help("编辑")
                .disabled(M.engine.isBusy)
            Button { confirmingDelete = l } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).foregroundColor(DS.Palette.error).help("删除")
                .disabled(M.engine.isBusy)
        }
        .padding(DS.Spacing.m)
        .background(DS.Palette.fillFaint)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
    }

    private func reloadListeners() {
        listeners = M.inboundListeners()
    }

    private func toggle(_ l: InboundListener, _ on: Bool) {
        var list = listeners
        guard let i = list.firstIndex(where: { $0.name == l.name }) else { return }
        list[i].isEnabled = on
        // 先落本地缓存（勾选立即跟手），保存失败时事务会回滚磁盘，重新读盘即回到真实状态。
        listeners = list
        M.saveInboundListeners(list) { ok in
            if !ok { reloadListeners() }
        }
    }
}

struct ListenerEditorSheet: View {
    @EnvironmentObject var M: AppModel
    @Environment(\.dismiss) private var dismiss
    let existing: [InboundListener]
    let editing: InboundListener?
    let onClose: () -> Void

    @State private var name = ""
    @State private var type: ListenerType = .tunnel
    @State private var port = ""
    @State private var target = ""
    @State private var listen = InboundListener.loopback
    @State private var tcp = true
    @State private var udp = false
    @State private var error = ""
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.l) {
            Text(editing == nil ? "添加端口转发" : "编辑端口转发").font(.dsCardLabel)

            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                Text("名称").font(.dsBody).foregroundColor(.secondary)
                TextField("如 fwd-nas（会显示在连接页的「来源」里）", text: $name)
                    .inputStyle().font(.dsMono)

                Text("类型").font(.dsBody).foregroundColor(.secondary)
                DSMenuPicker(selection: $type, choices: ListenerType.allCases.map {
                    DSChoice($0.label, $0)
                })
                .frame(width: 200)

                Text("监听端口").font(.dsBody).foregroundColor(.secondary)
                TextField("如 18080", text: $port).inputStyle().font(.dsMono)

                if type.needsTarget {
                    Text("目标地址（IP:端口）").font(.dsBody).foregroundColor(.secondary)
                    TextField("如 192.168.1.233:8080", text: $target).inputStyle().font(.dsMono)
                }

                Text("协议").font(.dsBody).foregroundColor(.secondary)
                HStack(spacing: DS.Spacing.l) {
                    Toggle("TCP", isOn: $tcp).toggleStyle(.checkbox)
                    Toggle("UDP", isOn: $udp).toggleStyle(.checkbox)
                }

                HStack {
                    Text("允许局域网访问").font(.dsBody)
                    Spacer(minLength: DS.Spacing.s)
                    DSCompactSwitch(isOn: listen == InboundListener.anyAddress,
                                    accessibilityText: "允许局域网访问") {
                        listen = (listen == InboundListener.anyAddress)
                            ? InboundListener.loopback : InboundListener.anyAddress
                    }
                }
                Text(listen == InboundListener.anyAddress
                     ? "监听 0.0.0.0：同网段的任何设备都能连这个端口。只在你确实要从别的设备访问时开启。"
                     : "监听 127.0.0.1：只有本机能连，不对外开放。")
                    .font(.dsCaption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !error.isEmpty {
                Text(error).font(.dsBody).foregroundColor(DS.Palette.error)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("取消") { onClose(); dismiss() }.dsButton()
                Spacer()
                Button("保存") { Task { await save() } }
                    .dsButton(.prominent)
                    .disabled(M.engine.isBusy)
            }
        }
        .padding(DS.Spacing.xl)
        .frame(width: 480)
        .onAppear(perform: loadOnce)
    }

    private func loadOnce() {
        guard !loaded else { return }
        loaded = true
        guard let e = editing else { return }
        name = e.name
        type = e.type
        port = "\(e.port)"
        target = e.target
        listen = e.listen
        tcp = e.network.contains(.tcp)
        udp = e.network.contains(.udp)
    }

    private func save() async {
        error = ""
        var network: Set<ListenerNetwork> = []
        if tcp { network.insert(.tcp) }
        if udp { network.insert(.udp) }
        let candidate = InboundListener(name: name.trimmingCharacters(in: .whitespaces),
                                        type: type,
                                        port: Int(port.trimmingCharacters(in: .whitespaces)) ?? 0,
                                        listen: listen,
                                        target: target.trimmingCharacters(in: .whitespaces),
                                        network: network,
                                        isEnabled: editing?.isEnabled ?? true)
        // 编辑时先把自己从「已存在」里去掉，否则一定报重名。
        let others = existing.filter { $0.name != editing?.name }
        if let reason = InboundListenerStore.validate(candidate, existing: others,
                                                      reservedPorts: M.reservedInboundPorts()) {
            error = reason
            return
        }
        // 端口被其它进程占着：`mihomo -t` 查不出来（它不探测端口），必须自己问系统。
        if let owner = await Task.detached(priority: .userInitiated, operation: {
            AppModel.portOwnerDescription(candidate.port)
        }).value {
            error = "端口 \(candidate.port) 已被「\(owner)」占用，请换一个端口"
            return
        }

        var list = existing
        if let e = editing, let i = list.firstIndex(where: { $0.name == e.name }) {
            list[i] = candidate
        } else {
            list.append(candidate)
        }
        M.saveInboundListeners(list) { ok in
            if ok { onClose(); dismiss() }
        }
    }
}

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
                        Text("端口设为 0 即禁用。建议绝大多数应用使用混合端口（兼容 HTTP 与 SOCKS5）。系统代理仅接管遵守系统代理设置的应用流量（UDP/QUIC 与绕过列表不经过内核），需要完整接管请开启 TUN。")
                            .font(.dsBody).foregroundColor(.secondary).padding(.top, DS.Spacing.s)
                    }
                    PortForwardingCard()

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
                            .font(.dsBody).foregroundColor(.secondary).padding(.top, DS.Spacing.s)
                    }
                    Card(title: "局域网网关 (旁路由)", icon: "network.badge.shield.half.filled") {
                        VStack(spacing: 2) {
                            HStack {
                                Text("作为网关中枢").font(.dsBody); Spacer()
                                if M.engine.isBusy {
                                    ProgressView().controlSize(.mini).scaleEffect(DS.Progress.miniScale)
                                }
                                DSCompactSwitch(isOn: M.gatewayModeOn,
                                                isEnabled: !M.engine.isBusy,
                                                accessibilityText: "作为网关中枢") {
                                    M.toggleGatewayMode()
                                }
                            }.padding(.vertical, DS.Spacing.s)
                        }
                        Text("开启后将自动配置 IP 转发并接管局域网内其他所有设备的流量（需配合 TUN）。其他设备需将网关和 DNS 指向本机的局域网 IP。")
                            .font(.dsBody).foregroundColor(.secondary).padding(.top, DS.Spacing.s)
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
                HStack(spacing: DS.Spacing.s) {
                    Text(dev.ip)
                        .font(.dsMonoBold)
                    // 身份一行：厂商 · 类型（推测）。拿不到就如实说「未知」——
                    // ARP 只覆盖同网段最近通信过的设备，跨 VLAN 时本来就没有。
                    Text(dev.identitySummary.isEmpty ? "身份未知" : dev.identitySummary)
                        .font(.dsCaption)
                        .foregroundColor(dev.identitySummary.isEmpty ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                HStack(spacing: DS.Spacing.m) {
                    Label("\(dev.activeConnections) 连接", systemImage: "point.3.connected.trianglepath.dotted")
                    Label("\(dev.durationString)", systemImage: "clock")
                    if !dev.mac.isEmpty {
                        Text(dev.mac).font(.dsMono).foregroundColor(.secondary)
                    }
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
        .contextMenu {
            Button("复制 IP") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(dev.ip, forType: .string)
            }
            Button("复制 MAC") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(dev.mac, forType: .string)
            }
            .disabled(dev.mac.isEmpty)
        }
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
                            if M.engine.isBusy {
                                ProgressView().controlSize(.mini).scaleEffect(DS.Progress.miniScale)
                            }
                            DSCompactSwitch(isOn: M.tunOn,
                                            isEnabled: !M.engine.isBusy,
                                            accessibilityText: "TUN 模式") {
                                M.toggleTUN()
                            }
                                .disabled(M.engine.isBusy)
                                .opacity(M.engine.isBusy ? 0.55 : 1)
                        }.padding(.vertical, DS.Spacing.s)
                        NPicker("协议栈", "tun", "stack", [("gvisor","gVisor"),("system","System"),("mixed","Mixed")])
                        NToggle("自动路由", "tun", "auto-route")
                        NToggle("自动检测网卡", "tun", "auto-detect-interface")
                        NList("DNS 劫持", "tun", "dns-hijack", placeholder: "any:53")
                        NList("路由排除网段", "tun", "route-exclude-address", placeholder: "192.168.0.0/16")
                    }
                    Text("用户态 UTUN (AF_SYSTEM)，不占 VPN 插槽。在「网络拓扑」中排除虚拟网段，可避免抢占其路由。")
                        .font(.dsBody).foregroundColor(.secondary).padding(.top, DS.Spacing.s)
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
                        .font(.dsBody).foregroundColor(.secondary).padding(.top, DS.Spacing.s)
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
    // outline only (design.md §6.8) — no .fill variants
    private let tabs: [(String, String, String)] = [
        ("入站", "network", "arrow.down.right.circle"),
        ("TUN", "tun", "shield"),
        ("DNS", "dns", "network"),
        ("嗅探", "sniffer", "scope"),
        ("Tailnet", "tailscale", "point.3.connected.trianglepath.dotted"),
        ("内核", "kernel", "cpu")
    ]

    var body: some View {
        VStack(spacing: 0) {
            // 顶栏交给共享 PageToolbar（P2-3）：与设置页/日志页/规则页同一条契约
            PageToolbar(leading: {
                DSSegmentedControl(selection: $tab, choices: tabs.map {
                    DSChoice($0.0, $0.1, systemImage: $0.2)
                })
            }, actions: { EmptyView() })

            // Tab 下方的上下文操作行：仅当当前 tab 提供页面级操作时显示
            // 放在分割线下方，避免顶栏高度因 DNS 动作行抖动、与侧栏分割线错位
            if tab == "dns" {
                HStack(spacing: DS.Spacing.s) {
                    Spacer(minLength: 0)
                    Button { M.flushDnsCache() } label: { Label("刷新缓存", systemImage: "arrow.clockwise") }
                        .dsButton()
                    Button { M.clearAllCache() } label: { Label("清空", systemImage: "trash") }
                        .dsButton()
                }
                .padding(.horizontal, DS.Layout.pageContentInset)
                .padding(.vertical, DS.Spacing.m)
            }
            Group {
                switch tab {
                case "tun": TunPage()
                case "dns": DnsPage()
                case "sniffer": SnifferPage()
                case "tailscale": TailscalePage()
                case "kernel": KernelMgmtPage()
                default: NetworkPage()
                }
            }
        }
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
                        .dsButton(.prominent)

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
        // These rows carry ports: non-numeric input ("789o", a cleared field)
        // must not silently commit as 0 — that would land in config.yaml and
        // reload. Leave the edit on screen (hasChanges stays true) instead.
        guard let n = Int(text) else { return }
        hasChanges = false
        Task {
            let ok = persistent ? await M.patchPersistent([key: n]) : await M.patch([key: n])
            // 写入被拒（校验失败 / 内核忙 / 事务回滚）：把输入框弹回内核真值，
            // 别让一个没落地的数字留在界面上冒充“已生效”。
            if !ok { text = configValue }
        }
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
            // 统一用紧凑开关（design.md §6.7）：系统 NSSwitch 在当前 macOS 上是
            // 54×24pt 固定尺寸，比这一行的 12pt 文字大得多。
            DSCompactSwitch(isOn: (M.configs[key] as? Bool) == true,
                            isEnabled: !M.engine.isBusy,
                            accessibilityText: label) {
                let v = !((M.configs[key] as? Bool) == true)
                Task {
                    // 没有本地 @State：开关的值直接读 M.configs。写入被拒时
                    // patchPersistent/patch 已弹出原因并从内核真值重同步，开关
                    // 自己就回到原位，因此这里的返回值没有可回弹的状态。
                    if persistent { _ = await M.patchPersistent([key: v]) } else { _ = await M.patch([key: v]) }
                }
            }
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
            HStack(spacing: DS.Spacing.s) {
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
                        .dsButton(.prominent)

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
        Task {
            let ok = persistent ? await M.patchPersistent([key: text]) : await M.patch([key: text])
            // 失败回弹：输入框里的草稿不能比磁盘更“新”。
            if !ok { text = (M.configs[key] as? String) ?? "" }
        }
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
            DSMenuPicker(selection: Binding<String>(
                get: {
                    let val = (M.configs[key] as? String) ?? ""
                    return options.contains(where: { $0.0 == val }) ? val : (options.first?.0 ?? "")
                },
                set: { v in Task { if persistent { _ = await M.patchPersistent([key: v]) } else { _ = await M.patch([key: v]) } } }
            ), choices: options.map { DSChoice($0.1, $0.0) })
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
    private func commit() {
        Task {
            let ok = persistent ? await M.patchPersistent([key: items]) : await M.patch([key: items])
            // 失败回弹到磁盘/内核里的真实列表，别留一条从没落地的条目。
            if !ok { items = (M.configs[key] as? [Any])?.map { "\($0)" } ?? [] }
        }
    }

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
                    Task {
                        if await M.patchPersistent(["geox-url": geo]) == false {
                            // 失败回弹到真实值，避免界面显示一个没写进配置的下载源。
                            let current = M.configs["geox-url"] as? [String: Any] ?? [:]
                            text = (current[sub] as? String) ?? defaultURL
                        }
                    }
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
            let current = (nestedDict(M, parent)[sub] as? Bool) == true
            DSCompactSwitch(isOn: current,
                            isEnabled: !M.engine.isBusy,
                            accessibilityText: label) {
                let previous = current
                let v = !current
                // Optimistic UI update to prevent toggle flickering/rollback
                var currentParent = M.configs[parent] as? [String: Any] ?? [:]
                currentParent[sub] = v
                M.configs[parent] = currentParent

                Task {
                    let ok = persistent ? await M.patchPersistent([parent: [sub: v]]) : await M.patch([parent: [sub: v]])
                    if !ok {
                        // 内核/磁盘拒绝了这笔写入：把乐观渲染的开关弹回真值。
                        // 不回弹就是“绿灯开着 + 红色错误 toast”并存的假象。
                        var revert = M.configs[parent] as? [String: Any] ?? [:]
                        revert[sub] = previous
                        M.configs[parent] = revert
                    }
                }
            }
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
            DSMenuPicker(selection: Binding<String>(
                get: {
                    let val = ((nestedDict(M, parent)[sub] as? String) ?? "").lowercased()
                    return options.first(where: { $0.0.lowercased() == val })?.0 ?? (options.first?.0 ?? "")
                },
                set: { v in
                    Task {
                        if persistent {
                            _ = await M.patchPersistent([parent: [sub: v]])
                        } else {
                            _ = await M.patch([parent: [sub: v]])
                        }
                    }
                }
            ), choices: options.map { DSChoice($0.1, $0.0) })
            .frame(width: DS.Layout.fieldTrailing, alignment: .trailing)
        }.padding(.vertical, DS.Spacing.s)
    }
}

/// 可持久化的嵌套配置输入框（`parent.sub`）。
///
/// P2-1（类型契约，别再踩）：`persistent` 默认 **true** —— 用它渲染的字段会立刻写进
/// `config.yaml` 并触发内核重载，不是"只改运行时"。因此这两类东西禁止用它渲染：
///   1. **密钥 / 令牌**：它没有掩码能力，会明文显示在屏幕上、明文落在 0600 的
///      config.yaml 里。API secret 这类字段必须走专门的密码输入控件；
///   2. 只想临时生效的调试值（写盘后 reload 会连带按文件重读其他 load-time 设置）。
/// 当前两个调用点（DnsPage 的 `fake-ip-range` / `listen`）都是非敏感字段。
struct NText: View {
    @EnvironmentObject var M: AppModel
    let parent: String; let sub: String; let label: String; let placeholder: String; let persistent: Bool
    init(_ label: String, _ parent: String, _ sub: String, placeholder: String = "", persistent: Bool = true) {
        self.label = label; self.parent = parent; self.sub = sub; self.placeholder = placeholder; self.persistent = persistent
    }
    @State private var text = ""
    @FocusState private var isFocused: Bool
    private var configValue: String { (nestedDict(M, parent)[sub] as? String) ?? "" }
    var body: some View {
        HStack {
            Text(label).font(.dsBody); Spacer()
            TextField(placeholder, text: $text)
                .inputStyle()
                .font(.dsMono)
                .multilineTextAlignment(.trailing)
                .focused($isFocused)
                .onSubmit { commit() }
                // N14: commit on blur too — same mental model as NumRow/TextRow;
                // a value typed then abandoned by clicking elsewhere is now kept
                // instead of silently dropped.
                .onChange(of: isFocused) { _, focused in
                    if !focused && text != configValue { commit() }
                }
                // Resync when the config changes under us (other entry point,
                // slow refresh) so a stale draft doesn't get committed later.
                .onChange(of: configValue) { _, newValue in text = newValue }
                .frame(width: DS.Layout.fieldTrailing, alignment: .trailing)
        }.padding(.vertical, DS.Spacing.s)
        .onAppear { text = configValue }
    }
    private func commit() {
        Task {
            let ok = persistent ? await M.patchPersistent([parent: [sub: text]]) : await M.patch([parent: [sub: text]])
            // 失败回弹：界面上的值必须等于真正生效的值。
            if !ok { text = configValue }
        }
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
        // N12: resync from config when it changes under us (profile switch,
        // subscription update) — the items snapshot is otherwise stale, and the
        // next add/remove would commit the whole stale list over the new config.
        .onChange(of: configItems) { _, newValue in items = newValue }
    }
    private var configItems: [String] {
        (nestedDict(M, parent)[sub] as? [Any])?.map { "\($0)" } ?? []
    }
    private func commit() {
        Task {
            let ok = persistent ? await M.patchPersistent([parent: [sub: items]]) : await M.patch([parent: [sub: items]])
            // 失败回弹到真实列表，避免界面比配置多/少一条。
            if !ok { items = configItems }
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
                            .font(.dsBody).foregroundColor(.secondary).padding(.top, DS.Spacing.s)
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
                                        // Unified restore: port-liveness gate +
                                        // verified write — never an optimistic
                                        // `systemProxyOn = true`.
                                        _ = await M.restoreSystemProxy(reason: "内核重启")
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
