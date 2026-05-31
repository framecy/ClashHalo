// Pages — Proxies, Connections, Rules, Logs, Config, Settings, MenuBar.
import SwiftUI

// MARK: - Proxies

struct ProxiesPage: View {
    @EnvironmentObject var M: AppModel
    @State private var collapsed: Set<String> = []

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                HStack {
                    Text("\(M.groups.count) 组 · \(M.nodes.count) 节点")
                        .font(.caption).foregroundColor(.secondary)
                    Spacer()
                    Button { M.testAll() } label: { Label("全部测速", systemImage: "bolt.fill") }
                        .controlSize(.small)
                }
                if M.groups.isEmpty {
                    ContentUnavailable("正在加载代理…", "arrow.triangle.2.circlepath")
                }
                ForEach(M.groups) { g in groupCard(g) }
            }
            .padding(18)
        }
    }

    private func groupCard(_ g: ProxyGroup) -> some View {
        let isOpen = !collapsed.contains(g.id)
        return Card {
            VStack(spacing: 0) {
                // header
                Button {
                    if isOpen { collapsed.insert(g.id) } else { collapsed.remove(g.id) }
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: "chevron.right")
                            .font(.caption2).foregroundColor(.secondary)
                            .rotationEffect(.degrees(isOpen ? 90 : 0))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(g.name).font(.callout).fontWeight(.semibold)
                            Text("\(g.type) · \(g.now)").font(.caption).foregroundColor(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button { M.testGroup(g) } label: { Image(systemName: "bolt") }
                            .buttonStyle(.borderless).controlSize(.small)
                        Text("\(g.all.count)").font(.caption2)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Capsule().fill(Color.primary.opacity(0.08)))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isOpen {
                    Divider().padding(.vertical, 8)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                        ForEach(g.all, id: \.self) { name in nodeChip(group: g, name: name) }
                    }
                }
            }
        }
    }

    private func nodeChip(group: ProxyGroup, name: String) -> some View {
        let on = group.now == name
        let node = M.nodes[name]
        let isGroup = M.groups.contains { $0.id == name }
        let delay = node?.delay ?? 0
        let busy = M.testing.contains(name)
        return Button {
            if group.selectable { M.select(group: group.id, name: name) }
        } label: {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.caption).fontWeight(on ? .semibold : .regular)
                        .foregroundColor(on ? M.accent : .primary).lineLimit(1)
                    Text(isGroup ? "组" : (node?.type ?? "—")).font(.system(size: 9)).foregroundColor(.secondary)
                }
                Spacer(minLength: 2)
                if busy {
                    ProgressView().controlSize(.mini).scaleEffect(0.6)
                } else if !isGroup {
                    Text(fmtDelay(delay)).font(.system(size: 10, design: .monospaced)).foregroundColor(delayColor(delay))
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(on ? M.accent.opacity(0.12) : Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(on ? M.accent.opacity(0.4) : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!group.selectable)
    }
}

// MARK: - Connections

struct ConnectionsPage: View {
    @EnvironmentObject var M: AppModel
    @State private var q = ""

    var body: some View {
        let rows = M.conns.filter {
            q.isEmpty || "\($0.host)\($0.process)\($0.chain)\($0.rule)".localizedCaseInsensitiveContains(q)
        }
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("搜索域名 / 进程 / 规则", text: $q).textFieldStyle(.plain)
                Spacer()
                Text("\(rows.count) 活跃").font(.caption).foregroundColor(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()

            if rows.isEmpty {
                ContentUnavailable(q.isEmpty ? "暂无活跃连接" : "无匹配结果", "point.3.connected.trianglepath.dotted")
                    .frame(maxHeight: .infinity)
            } else {
                Table(rows) {
                    TableColumn("目标") { c in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(c.host).font(.caption).fontWeight(.medium).lineLimit(1)
                            Text("\(c.dstIP):\(c.port)").font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
                        }
                    }.width(min: 180, ideal: 240)
                    TableColumn("进程") { c in Text(c.process).font(.caption).lineLimit(1) }.width(min: 80, ideal: 120)
                    TableColumn("规则") { c in Text(c.rule).font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary).lineLimit(1) }.width(min: 100, ideal: 150)
                    TableColumn("链路") { c in Text(c.chain).font(.caption).foregroundColor(M.accent).lineLimit(1) }.width(min: 100, ideal: 160)
                    TableColumn("↓") { c in Text(fmtRate(Double(c.downRate))).font(.system(size: 10, design: .monospaced)) }.width(70)
                    TableColumn("↑") { c in Text(fmtRate(Double(c.upRate))).font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary) }.width(70)
                }
            }
        }
    }
}

// MARK: - Rules

struct RulesPage: View {
    @EnvironmentObject var M: AppModel
    @State private var rules: [RuleEntry] = []
    @State private var q = ""

    var body: some View {
        let rows = rules.enumerated().filter {
            q.isEmpty || "\($0.element.type)\($0.element.payload)\($0.element.proxy)".localizedCaseInsensitiveContains(q)
        }
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("搜索规则", text: $q).textFieldStyle(.plain)
                Spacer()
                Text("\(rules.count) 条规则").font(.caption).foregroundColor(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(rows, id: \.offset) { item in
                        let r = item.element
                        HStack(spacing: 10) {
                            Text(r.type).font(.system(size: 10, weight: .medium))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(Color.primary.opacity(0.08)))
                                .frame(width: 130, alignment: .leading)
                            Text(r.payload.isEmpty ? "—" : r.payload).font(.caption.monospaced()).lineLimit(1)
                            Spacer()
                            Text(r.proxy).font(.caption).foregroundColor(M.accent)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        Divider().opacity(0.4)
                    }
                }
            }
        }
        .task {
            if let p = try? await M.api.fetchRules() { rules = p.rules }
        }
    }
}

// MARK: - Logs

struct LogsPage: View {
    @EnvironmentObject var M: AppModel
    @State private var level = "all"
    @State private var q = ""
    @State private var paused = false
    @State private var frozen: [Log] = []

    var body: some View {
        let source = paused ? frozen : M.logs
        let rows = source.filter {
            (level == "all" || $0.level == level) &&
            (q.isEmpty || $0.text.localizedCaseInsensitiveContains(q))
        }
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("过滤日志", text: $q).textFieldStyle(.plain).frame(maxWidth: 180)
                Picker("", selection: $level) {
                    Text("全部").tag("all"); Text("INFO").tag("info")
                    Text("WARN").tag("warning"); Text("ERROR").tag("error")
                }.pickerStyle(.segmented).frame(width: 240).labelsHidden()
                Spacer()
                Button { paused.toggle(); if paused { frozen = M.logs } } label: {
                    Label(paused ? "继续" : "暂停", systemImage: paused ? "play.fill" : "pause.fill")
                }.controlSize(.small)
                Button { exportLogs(rows) } label: { Label("导出", systemImage: "square.and.arrow.up") }
                    .controlSize(.small)
                HStack(spacing: 4) {
                    Circle().fill(paused ? Color.secondary : Color.green).frame(width: 5, height: 5)
                    Text("\(rows.count) 行").font(.caption).foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            ScrollViewReader { sp in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(rows) { l in
                            HStack(alignment: .top, spacing: 8) {
                                Text(l.time).font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
                                Text(l.level.uppercased()).font(.system(size: 9, weight: .bold))
                                    .foregroundColor(logColor(l.level)).frame(width: 46, alignment: .leading)
                                Text(l.text).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 1)
                            .id(l.id)
                        }
                    }.padding(.vertical, 6)
                }
                .onChange(of: M.logs.count) {
                    if !paused, let last = rows.last { withAnimation { sp.scrollTo(last.id, anchor: .bottom) } }
                }
            }
            if source.isEmpty {
                ContentUnavailable("等待日志流…", "doc.text.magnifyingglass").frame(maxHeight: .infinity)
            }
        }
    }

    private func exportLogs(_ rows: [Log]) {
        let text = rows.map { "\($0.time) [\($0.level.uppercased())] \($0.text)" }.joined(separator: "\n")
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "clashpow-logs.txt"
        panel.allowedContentTypes = [.plainText]
        if panel.runModal() == .OK, let url = panel.url {
            try? text.write(to: url, atomically: true, encoding: .utf8)
            M.showToast("已导出 \(rows.count) 行日志")
        }
    }
    private func logColor(_ l: String) -> Color {
        switch l { case "warning": return .orange; case "error": return .red; case "debug": return .secondary; default: return .blue }
    }
}

// MARK: - Subscriptions (proxy providers)

struct SubscriptionsPage: View {
    @EnvironmentObject var M: AppModel
    @State private var providers: [ProviderEntry] = []
    @State private var busy: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                HStack {
                    Text("\(providers.count) 个订阅").font(.caption).foregroundColor(.secondary)
                    Spacer()
                    Button { Task { await updateAll() } } label: { Label("全部更新", systemImage: "arrow.clockwise") }
                        .controlSize(.small)
                }
                if providers.isEmpty {
                    ContentUnavailable("无 HTTP 订阅 (proxy-providers)", "icloud")
                }
                ForEach(providers, id: \.name) { p in card(p) }
            }
            .padding(18)
        }
        .task { await reload() }
    }

    private func card(_ p: ProviderEntry) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "icloud.fill").foregroundColor(M.accent)
                    Text(p.name).font(.callout).fontWeight(.semibold)
                    Text("\(p.proxies?.count ?? 0) 节点").font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                    Spacer()
                    if busy.contains(p.name) {
                        ProgressView().controlSize(.small)
                    } else {
                        Button { Task { await update(p.name) } } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.borderless)
                    }
                }
                if let s = p.subscriptionInfo, let total = s.Total, total > 0 {
                    let used = (s.Upload ?? 0) + (s.Download ?? 0)
                    let frac = min(1, Double(used) / Double(total))
                    VStack(alignment: .leading, spacing: 3) {
                        ProgressView(value: frac).tint(frac > 0.85 ? .red : M.accent)
                        HStack {
                            Text("\(fmtBytes(Double(used))) / \(fmtBytes(Double(total)))").font(.caption2.monospaced()).foregroundColor(.secondary)
                            Spacer()
                            if let exp = s.Expire, exp > 0 {
                                Text("到期 " + dateStr(exp)).font(.caption2.monospaced()).foregroundColor(.secondary)
                            }
                        }
                    }
                }
                if let u = p.updatedAt, !u.hasPrefix("0001") {
                    Text("更新于 " + String(u.prefix(19)).replacingOccurrences(of: "T", with: " "))
                        .font(.caption2).foregroundColor(.secondary)
                }
            }
        }
    }

    private func reload() async {
        guard let p = try? await M.api.fetchProviders() else { return }
        providers = p.providers.values.filter { $0.vehicleType == "HTTP" }.sorted { $0.name < $1.name }
    }
    private func update(_ name: String) async {
        busy.insert(name)
        try? await M.api.updateProvider(name)
        try? await Task.sleep(nanoseconds: 800_000_000)
        await reload(); busy.remove(name)
        M.showToast("已更新订阅「\(name)」")
    }
    private func updateAll() async { for p in providers { await update(p.name) } }
    private func dateStr(_ unix: Int64) -> String {
        let d = Date(timeIntervalSince1970: TimeInterval(unix))
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: d)
    }
}

// MARK: - DNS (resolver query + Fake-IP from live connections)

struct DnsPage: View {
    @EnvironmentObject var M: AppModel
    @State private var query = ""
    @State private var result = ""
    @State private var resolving = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Card(title: "DNS 解析") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            TextField("输入域名，如 google.com", text: $query)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { Task { await resolve() } }
                            Button { Task { await resolve() } } label: {
                                if resolving { ProgressView().controlSize(.small) } else { Text("解析") }
                            }.disabled(query.isEmpty || resolving)
                        }
                        if !result.isEmpty {
                            Text(result).font(.caption.monospaced()).foregroundColor(.secondary)
                                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }

                // Fake-IP mappings observed in live connections
                let fakeip = M.conns.filter { $0.dstIP.hasPrefix("198.18.") || $0.dstIP.hasPrefix("198.19.") }
                Card(title: "Fake-IP 映射 · \(fakeip.count)（来自活跃连接）") {
                    if fakeip.isEmpty {
                        Text("当前无 Fake-IP 连接（需内核启用 dns.enhanced-mode: fake-ip 且有代理流量）")
                            .font(.caption).foregroundColor(.secondary)
                    } else {
                        VStack(spacing: 4) {
                            ForEach(fakeip.prefix(50)) { c in
                                HStack {
                                    Text(c.host).font(.caption).lineLimit(1)
                                    Spacer()
                                    Text(c.dstIP).font(.caption.monospaced()).foregroundColor(M.accent)
                                }
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(18)
        }
    }
    private func resolve() async {
        resolving = true; defer { resolving = false }
        guard let j = try? await M.api.dnsQuery(name: query) else { result = "解析失败"; return }
        if let answers = j["Answer"] as? [[String: Any]] {
            result = answers.compactMap { "\($0["data"] ?? "")" }.joined(separator: "\n")
        } else if let msg = j["message"] as? String {
            result = msg
        } else {
            result = "无结果"
        }
        if result.isEmpty { result = "无 A 记录" }
    }
}

// MARK: - SD-WAN coexistence (topology + conflict detection)

struct SdwanPage: View {
    @EnvironmentObject var M: AppModel
    @State private var ifaces: [NetIface] = []
    @State private var routes: [(dest: String, iface: String)] = []

    private var sdwanCount: Int { ifaces.filter { $0.kind.sdwan }.count }
    private var hasDefaultViaTun: Bool { routes.contains { $0.dest == "default" } }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                // status banner
                HStack(spacing: 12) {
                    Image(systemName: "shield.lefthalf.filled").font(.title).foregroundColor(hasDefaultViaTun ? .orange : M.accent)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(hasDefaultViaTun ? "检测到 TUN 默认路由" : "智能路由隔离已生效").font(.callout).fontWeight(.semibold)
                        Text(hasDefaultViaTun
                             ? "存在经 utun 的默认路由，可能与 SD-WAN 抢占。建议仅注入精确网段。"
                             : "代理仅注入精确网段，未抢占默认路由；\(sdwanCount) 个 SD-WAN 接口路由保持完整。")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    VStack { Text("\(hasDefaultViaTun ? 1 : 0)").font(.title.monospaced()).fontWeight(.bold)
                             .foregroundColor(hasDefaultViaTun ? .orange : M.accent)
                        Text("路由冲突").font(.caption2).foregroundColor(.secondary) }
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.06)))

                // interfaces
                Card(title: "网络接口拓扑 · \(ifaces.count)") {
                    VStack(spacing: 8) {
                        ForEach(ifaces) { i in ifaceRow(i) }
                        if ifaces.isEmpty { Text("正在扫描接口…").font(.caption).foregroundColor(.secondary) }
                    }
                }

                // utun routes
                Card(title: "UTUN 路由表 · \(routes.count)") {
                    VStack(spacing: 4) {
                        if routes.isEmpty { Text("无 utun 路由").font(.caption).foregroundColor(.secondary) }
                        ForEach(routes.indices, id: \.self) { idx in
                            HStack {
                                Text(routes[idx].dest).font(.caption.monospaced())
                                Spacer()
                                Image(systemName: "arrow.right").font(.caption2).foregroundColor(.secondary)
                                Text(routes[idx].iface).font(.caption.monospaced()).foregroundColor(M.accent)
                            }
                        }
                    }
                }

                Label("进程级分流 (SO_USER_COOKIE + PF) 与路由注入需特权 Helper（代码签名后于 v1.0 启用）",
                      systemImage: "lock.shield").font(.caption2).foregroundColor(.secondary)
                Spacer(minLength: 0)
            }
            .padding(18)
        }
        .onAppear { rescan() }
    }

    private func ifaceRow(_ i: NetIface) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon(i.kind)).foregroundColor(color(i.kind)).frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(i.name).font(.callout.monospaced()).fontWeight(.medium)
                    Text(i.kind.rawValue).font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(color(i.kind).opacity(0.15))).foregroundColor(color(i.kind))
                }
                Text(i.ipv4.joined(separator: ", ").isEmpty ? "无 IPv4" : i.ipv4.joined(separator: ", "))
                    .font(.caption2.monospaced()).foregroundColor(.secondary)
            }
            Spacer()
            Circle().fill(i.isUp ? Color.green : Color.secondary.opacity(0.4)).frame(width: 7, height: 7)
        }
        .padding(.vertical, 3)
    }

    private func rescan() {
        ifaces = NetScanner.interfaces()
        routes = NetScanner.tunRoutes()
    }
    private func icon(_ k: IfaceKind) -> String {
        switch k {
        case .physical: return "wifi"
        case .proxyTun: return "shield.fill"
        case .tailscale: return "point.3.connected.trianglepath.dotted"
        case .zerotier: return "globe"
        case .oray: return "link"
        default: return "network"
        }
    }
    private func color(_ k: IfaceKind) -> Color {
        switch k {
        case .physical: return .blue
        case .proxyTun: return .green
        case .tailscale: return .teal
        case .zerotier: return .orange
        case .oray: return .purple
        default: return .secondary
        }
    }
}

// MARK: - Config (dual-mode editor: YAML source + structured form)

struct ConfigPage: View {
    @EnvironmentObject var M: AppModel
    @State private var mode = "yaml"            // yaml | form
    @State private var text = ""
    @State private var dirty = false
    @State private var validation: (ok: Bool, msg: String)? = nil
    @State private var applying = false

    static let configPath = NSHomeDirectory() + "/Library/Application Support/ClashPow/config.yaml"

    var body: some View {
        VStack(spacing: 0) {
            // toolbar
            HStack(spacing: 10) {
                Picker("", selection: $mode) {
                    Text("YAML 源码").tag("yaml"); Text("结构化表单").tag("form")
                }.pickerStyle(.segmented).frame(width: 220).labelsHidden()
                Spacer()
                if let v = validation {
                    Label(v.ok ? "校验通过" : v.msg,
                          systemImage: v.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.caption).foregroundColor(v.ok ? .green : .red).lineLimit(1)
                }
                Button("重新载入") { reload() }.controlSize(.small)
                Button {
                    apply()
                } label: {
                    if applying { ProgressView().controlSize(.small) }
                    else { Label("应用并热重载", systemImage: "checkmark") }
                }
                .controlSize(.small).buttonStyle(.borderedProminent).tint(M.accent)
                .disabled(applying || !dirty)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()

            if mode == "yaml" {
                YAMLEditor(text: $text, onChange: { dirty = true; validation = nil })
            } else {
                FormEditor(configs: M.configs, accent: M.accent)
            }
        }
        .onAppear { if text.isEmpty { reload() } }
    }

    private func reload() {
        text = (try? String(contentsOfFile: Self.configPath, encoding: .utf8))
            ?? "# 配置文件未找到：\(Self.configPath)\n# 引擎首次启动会生成默认配置\n"
        dirty = false; validation = nil
    }

    private func apply() {
        applying = true
        let yaml = text
        Task {
            // persist to the managed config file…
            try? yaml.write(toFile: Self.configPath, atomically: true, encoding: .utf8)
            // …and apply live via the engine (validates + rolls back on error)
            let (ok, err) = await M.engine.setConfig(yaml)
            applying = false; dirty = false
            validation = (ok, ok ? "校验通过" : (err ?? "校验失败"))
            M.showToast(ok ? "配置已热重载" : "配置错误，已回滚")
            if ok { await M.reconnect() }
        }
    }
}

// MARK: - Structured form (editable common fields)

private struct FormEditor: View {
    let configs: [String: Any]
    let accent: Color
    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Card(title: "入站端口") {
                    VStack(spacing: 9) {
                        kv("混合端口", str(configs["mixed-port"]))
                        kv("SOCKS 端口", str(configs["socks-port"]))
                        kv("运行模式", str(configs["mode"]))
                        kv("日志级别", str(configs["log-level"]))
                    }
                }
                Card(title: "TUN") {
                    let tun = configs["tun"] as? [String: Any] ?? [:]
                    VStack(spacing: 9) {
                        kv("启用", bool(tun["enable"]))
                        kv("协议栈", str(tun["stack"]))
                        kv("自动路由", bool(tun["auto-route"]))
                    }
                }
                Card(title: "DNS") {
                    let dns = configs["dns"] as? [String: Any] ?? [:]
                    VStack(spacing: 9) {
                        kv("启用", bool(dns["enable"]))
                        kv("增强模式", str(dns["enhanced-mode"]))
                        kv("Fake-IP 段", str(dns["fake-ip-range"]))
                    }
                }
                Text("结构化表单为只读概览；如需修改请用 YAML 源码模式编辑后「应用并热重载」。")
                    .font(.caption2).foregroundColor(.secondary)
                Spacer(minLength: 0)
            }.padding(18)
        }
    }
    private func kv(_ l: String, _ v: String) -> some View {
        HStack { Text(l).font(.caption).foregroundColor(.secondary); Spacer(); Text(v).font(.caption.monospaced()) }
    }
    private func str(_ v: Any?) -> String { v.map { "\($0)" } ?? "—" }
    private func bool(_ v: Any?) -> String { (v as? Bool) == true ? "是" : "否" }
}

// MARK: - YAML syntax-highlighting editor (NSTextView)

struct YAMLEditor: NSViewRepresentable {
    @Binding var text: String
    var onChange: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let tv = scroll.documentView as? NSTextView else { return scroll }
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.allowsUndo = true
        tv.backgroundColor = .textBackgroundColor
        tv.textContainerInset = NSSize(width: 8, height: 8)
        context.coordinator.textView = tv
        tv.string = text
        context.coordinator.highlight()
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let tv = context.coordinator.textView else { return }
        if tv.string != text {
            tv.string = text
            context.coordinator.highlight()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let parent: YAMLEditor
        weak var textView: NSTextView?
        init(_ p: YAMLEditor) { parent = p }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            parent.text = tv.string
            parent.onChange()
            highlight()
        }

        // Lightweight line-based YAML highlighter.
        func highlight() {
            guard let tv = textView, let storage = tv.textStorage else { return }
            let full = tv.string as NSString
            let sel = tv.selectedRange()
            storage.beginEditing()
            storage.addAttribute(.foregroundColor, value: NSColor.textColor, range: NSRange(location: 0, length: full.length))
            storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), range: NSRange(location: 0, length: full.length))
            apply(#"#[^\n]*"#, .systemGray, full, storage)                       // comments
            apply(#"^\s*[-]?\s*[\w.\-]+(?=\s*:)"#, .systemTeal, full, storage)    // keys
            apply(#":\s*[\"'][^\"'\n]*[\"']"#, .systemGreen, full, storage)       // quoted values
            apply(#":\s*-?\d+(\.\d+)?\b"#, .systemOrange, full, storage)          // numbers
            apply(#"\b(true|false|null)\b"#, .systemPurple, full, storage)        // literals
            storage.endEditing()
            tv.setSelectedRange(sel)
        }
        private func apply(_ pattern: String, _ color: NSColor, _ s: NSString, _ storage: NSTextStorage) {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return }
            re.enumerateMatches(in: s as String, range: NSRange(location: 0, length: s.length)) { m, _, _ in
                if let r = m?.range { storage.addAttribute(.foregroundColor, value: color, range: r) }
            }
        }
    }
}

// MARK: - Settings

struct SettingsPage: View {
    @EnvironmentObject var M: AppModel
    @State private var host = ""
    @State private var port = ""
    @State private var secret = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                // Engine (managed kernel)
                Card(title: "内核") {
                    VStack(spacing: 10) {
                        HStack {
                            Circle().fill(M.reachable ? Color.green : Color.red).frame(width: 8, height: 8)
                            Text(statusLine).font(.caption).foregroundColor(.secondary)
                            Spacer()
                            if M.engineManaged {
                                Button("重启内核", systemImage: "arrow.triangle.2.circlepath") {
                                    Task { await M.engine.restart(); try? await Task.sleep(nanoseconds: 3_000_000_000); await M.reconnect(); M.showToast("内核已重启") }
                                }.buttonStyle(.bordered).tint(.orange).controlSize(.small)
                            }
                        }
                        if M.engineManaged {
                            HStack {
                                Text("运行模式").font(.caption).foregroundColor(.secondary)
                                Text("ClashPow 引擎托管 (launchd)").font(.caption2)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Capsule().fill(M.accent.opacity(0.15))).foregroundColor(M.accent)
                                Spacer()
                                Text("运行 \(uptimeText)").font(.caption2.monospaced()).foregroundColor(.secondary)
                            }
                        }
                    }
                }
                // Manual connection override (when not engine-managed)
                Card(title: "手动连接 (高级)") {
                    VStack(spacing: 10) {
                        field("地址", text: $host, placeholder: "127.0.0.1")
                        field("端口", text: $port, placeholder: "9092")
                        SecureField("密钥 (secret)", text: $secret).textFieldStyle(.roundedBorder)
                        HStack {
                            Text("覆盖引擎自动发现，直连指定 mihomo").font(.caption2).foregroundColor(.secondary)
                            Spacer()
                            Button("应用并重连") {
                                M.api.host = host.isEmpty ? "127.0.0.1" : host
                                M.api.port = Int(port) ?? 9092
                                M.api.secret = secret
                                Task { await M.reconnect() }
                            }.buttonStyle(.borderedProminent)
                        }
                    }
                }
                Card(title: "外观") {
                    VStack(spacing: 10) {
                        Toggle("深色模式", isOn: $M.dark)
                        HStack {
                            Text("强调色").font(.caption).foregroundColor(.secondary)
                            Spacer()
                            ForEach(["green","blue","purple","orange"], id: \.self) { c in
                                Circle().fill(colorFor(c)).frame(width: 22, height: 22)
                                    .overlay(Circle().stroke(Color.primary, lineWidth: M.accentRaw == c ? 2 : 0))
                                    .onTapGesture { M.accentRaw = c }
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(18)
        }
        .onAppear { host = M.api.host; port = "\(M.api.port)"; secret = M.api.secret }
    }
    private var statusLine: String {
        if !M.reachable { return "未连接内核" }
        return "已连接 · mihomo \(M.version)" + (M.engineManaged ? " · 引擎 \(M.engine.engineVersion)" : "")
    }
    private var uptimeText: String {
        let s = M.engineUptime; let h = s / 3600; let m = (s % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m \(s % 60)s"
    }
    private func field(_ l: String, text: Binding<String>, placeholder: String) -> some View {
        HStack { Text(l).font(.caption).foregroundColor(.secondary).frame(width: 50, alignment: .leading)
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder) }
    }
    private func colorFor(_ s: String) -> Color { ["green":.green,"blue":.blue,"purple":.purple,"orange":.orange][s] ?? .green }
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
                        Text(M.reachable ? "mihomo \(M.version)" : "未连接").font(.caption2).foregroundColor(.secondary)
                    }
                }
                Spacer()
            }.padding(14)
            Divider()
            VStack(spacing: 8) {
                HStack {
                    Label(fmtRate(Double(M.curDown)), systemImage: "arrow.down").font(.caption.monospaced())
                    Spacer()
                    Label(fmtRate(Double(M.curUp)), systemImage: "arrow.up").font(.caption.monospaced()).foregroundColor(.secondary)
                }
                HStack {
                    Text("出口").font(.caption2).foregroundColor(.secondary)
                    Spacer()
                    Text(M.currentProxyName()).font(.caption).foregroundColor(M.accent)
                }
                Picker("", selection: Binding(get: { M.mode }, set: { M.setMode($0) })) {
                    Text("规则").tag("rule"); Text("全局").tag("global"); Text("直连").tag("direct")
                }.pickerStyle(.segmented).labelsHidden()
            }.padding(14)
            Divider()
            Button("退出 ClashPow") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain).font(.caption).padding(12)
        }.frame(width: 260)
    }
}

// MARK: - Shared empty state

struct ContentUnavailable: View {
    let text: String, icon: String
    init(_ t: String, _ i: String) { text = t; icon = i }
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 34)).foregroundColor(.secondary.opacity(0.5))
            Text(text).font(.callout).foregroundColor(.secondary)
        }.frame(maxWidth: .infinity).padding(40)
    }
}
