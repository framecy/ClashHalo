// Pages — Proxies, Connections, Rules, Logs, Config, Settings, MenuBar.
import SwiftUI

// MARK: - Proxies

struct ProxiesPage: View {
    @EnvironmentObject var M: AppModel
    @State private var collapsed: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            PageHead(title: "策略", desc: "\(M.groups.count) 组 · \(M.nodes.count) 节点") {
                Button {
                    collapsed = collapsed.count == M.groups.count ? [] : Set(M.groups.map(\.id))
                } label: { Label(collapsed.count == M.groups.count ? "全部展开" : "全部折叠", systemImage: "rectangle.expand.vertical") }
                    .controlSize(.small)
                Button { M.testAll() } label: { Label("全部测速", systemImage: "bolt.fill") }
                    .controlSize(.small).tint(M.accent).buttonStyle(.borderedProminent)
            }

            ScrollView {
                LazyVStack(spacing: 12) {
                    if M.groups.isEmpty {
                        ContentUnavailable("正在加载代理…", "arrow.triangle.2.circlepath")
                    }
                    ForEach(M.groups) { g in groupCard(g) }
                }
                .padding(.horizontal, 20).padding(.bottom, 24)
            }
        }
    }

    private func groupIcon(_ type: String) -> String {
        switch type {
        case "URLTest": return "bolt.badge.automatic.fill"
        case "Fallback": return "arrow.uturn.down.circle.fill"
        case "LoadBalance": return "arrow.left.arrow.right.circle.fill"
        case "Selector": return "hand.tap.fill"
        default: return "circle.grid.2x2.fill"
        }
    }

    private func groupCard(_ g: ProxyGroup) -> some View {
        let isOpen = !collapsed.contains(g.id)
        let cur = g.now
        let curDelay = M.nodes[cur]?.delay ?? 0
        return Card {
            VStack(spacing: 0) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        if isOpen { collapsed.insert(g.id) } else { collapsed.remove(g.id) }
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "chevron.right").font(.caption2).foregroundColor(.secondary)
                            .rotationEffect(.degrees(isOpen ? 90 : 0))
                        Image(systemName: groupIcon(g.type)).font(.callout).foregroundColor(M.accent).frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(g.name).font(.callout).fontWeight(.semibold)
                                Text(g.type).font(.system(size: 9)).foregroundColor(.secondary)
                                    .padding(.horizontal, 5).padding(.vertical, 1)
                                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                            }
                            HStack(spacing: 5) {
                                Text(cur).font(.caption).foregroundColor(M.accent).lineLimit(1)
                                if curDelay > 0 { Text("\(curDelay)ms").font(.system(size: 9, design: .monospaced)).foregroundColor(delayColor(curDelay)) }
                            }
                        }
                        Spacer()
                        Button { M.testGroup(g) } label: { Image(systemName: "bolt") }
                            .buttonStyle(.borderless).controlSize(.small).help("测速")
                        Text("\(g.all.count)").font(.caption2)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Capsule().fill(Color.primary.opacity(0.08)))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isOpen {
                    Divider().padding(.vertical, 8)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 168), spacing: 8)], spacing: 8) {
                        ForEach(g.all, id: \.self) { name in nodeChip(group: g, name: name) }
                    }
                }
            }
        }
    }

    private func nodeChip(group: ProxyGroup, name: String) -> some View {
        let on = (group.now) == name
        let node = M.nodes[name]
        let isGroup = M.groups.contains { $0.id == name }
        let delay = node?.delay ?? 0
        let busy = M.testing.contains(name)
        return Button {
            if group.selectable { M.select(group: group.id, name: name) }
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(name).font(.caption).fontWeight(on ? .semibold : .regular)
                        .foregroundColor(on ? M.accent : .primary).lineLimit(1)
                    Spacer(minLength: 2)
                    if on { Image(systemName: "checkmark.circle.fill").font(.caption2).foregroundColor(M.accent) }
                }
                HStack(spacing: 6) {
                    Text(isGroup ? "组" : (node?.type ?? "—")).font(.system(size: 9)).foregroundColor(.secondary)
                    Spacer(minLength: 2)
                    if busy {
                        ProgressView().controlSize(.mini).scaleEffect(0.55)
                    } else if !isGroup {
                        Circle().fill(delayColor(delay)).frame(width: 5, height: 5)
                        Text(fmtDelay(delay)).font(.system(size: 10, design: .monospaced)).foregroundColor(delayColor(delay))
                    } else {
                        Image(systemName: "chevron.right.circle").font(.system(size: 9)).foregroundColor(.secondary)
                    }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(on ? M.accent.opacity(0.12) : Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(on ? M.accent.opacity(0.45) : Color.clear, lineWidth: 1))
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
    @State private var showConfirmDisconnect = false

    var body: some View {
        VStack(spacing: 0) {
            PageHead(title: "连接", desc: "\(M.conns.count) 个活跃连接 · 实时速率") {
                Button(role: .destructive) { showConfirmDisconnect = true } label: { Label("全部断开", systemImage: "xmark.circle") }
                    .controlSize(.small)
            }

            HStack {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("搜索域名 / 进程 / 规则", text: $q).textFieldStyle(.plain)
                Spacer()
                Text("\(M.conns.filter { matches($0) }.count) 匹配").font(.caption).foregroundColor(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.3))
            Divider()

            let rows = M.conns.filter { matches($0) }
            if rows.isEmpty {
                ContentUnavailable(q.isEmpty ? "暂无活跃连接" : "无匹配结果", "point.3.connected.trianglepath.dotted")
                    .frame(maxHeight: .infinity)
            } else {
                Table(rows) {
                    TableColumn("目标") { c in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(c.host).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Text("\(c.dstIP):\(c.port)").font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
                        }
                    }.width(min: 180, ideal: 240)
                    TableColumn("进程") { c in Text(c.process).font(.system(size: 11)).foregroundColor(.secondary).lineLimit(1) }.width(min: 80, ideal: 120)
                    TableColumn("规则") { c in Text(c.rule).font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary).lineLimit(1) }.width(min: 100, ideal: 150)
                    TableColumn("链路") { c in
                        HStack(spacing: 4) {
                            Text(c.chain).font(.system(size: 11, weight: .semibold)).foregroundColor(c.category == "proxy" ? M.accent : .secondary).lineLimit(1)
                            Text(c.node).font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary)
                        }
                    }.width(min: 120, ideal: 180)
                    TableColumn("↓") { c in Text(fmtRate(Double(c.downRate))).font(.system(size: 10, design: .monospaced)) }.width(70)
                    TableColumn("↑") { c in Text(fmtRate(Double(c.upRate))).font(.system(size: 10, design: .monospaced)).foregroundColor(.secondary) }.width(70)
                }
            }
        }
        .confirmationDialog("确定要断开所有连接吗？", isPresented: $showConfirmDisconnect, titleVisibility: .visible) {
            Button("确定断开", role: .destructive) { M.closeAllConnections() }
        } message: {
            Text("这将中断所有正在进行的网络会话")
        }
    }

    private func matches(_ c: Conn) -> Bool {
        q.isEmpty || "\(c.host)\(c.process)\(c.chain)\(c.rule)".localizedCaseInsensitiveContains(q)
    }
}

// MARK: - Rules

struct RulesPage: View {
    @EnvironmentObject var M: AppModel
    @State private var q = ""
    @State private var editing: (idx: Int, text: String)? = nil
    @State private var showAdd = false
    @State private var newRule = ""

    private func matches(_ s: String) -> Bool { q.isEmpty || s.localizedCaseInsensitiveContains(q) }

    var body: some View {
        let enabled = M.inlineRules
        let disabled = M.disabledRules
        VStack(spacing: 0) {
            PageHead(title: "分流规则", desc: "\(enabled.count) 启用 · \(disabled.count) 禁用") {
                Button { newRule = ""; showAdd = true } label: { Label("添加规则", systemImage: "plus") }
                    .controlSize(.small).tint(M.accent).buttonStyle(.borderedProminent)
            }

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("搜索规则内容或策略", text: $q).textFieldStyle(.plain)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.3))
            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(enabled.indices), id: \.self) { idx in
                        let rule = enabled[idx]
                        if matches(rule) { row(rule, idx: idx, disabled: false, count: enabled.count) }
                    }
                    if !disabled.isEmpty {
                        HStack { Text("已禁用").font(.caption).fontWeight(.bold).foregroundColor(.secondary); Spacer() }
                            .padding(.horizontal, 14).padding(.top, 16).padding(.bottom, 8)
                        ForEach(Array(disabled.indices), id: \.self) { idx in
                            let rule = disabled[idx]
                            if matches(rule) { row(rule, idx: -1, disabled: true, count: 0) }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            RuleEditSheet(title: "编辑规则", initial: editing?.text ?? "") { newText in
                guard let e = editing else { return }
                var r = M.inlineRules; if e.idx >= 0 && e.idx < r.count { r[e.idx] = newText }
                Task { await M.applyRules(r) }; editing = nil
            } onCancel: { editing = nil }
        }
        .sheet(isPresented: $showAdd) {
            RuleEditSheet(title: "添加规则", initial: "") { t in
                Task { await M.applyRules(M.inlineRules + [t]) }; showAdd = false
            } onCancel: { showAdd = false }
        }
    }

    private func row(_ rule: String, idx: Int, disabled: Bool, count: Int) -> some View {
        let parts = rule.split(separator: ",", maxSplits: 2).map { $0.trimmingCharacters(in: .whitespaces) }
        let type = parts.first ?? rule
        let payload = parts.count > 1 ? parts[1] : ""
        let proxy = parts.count > 2 ? parts[2] : (parts.count > 1 && type == "MATCH" ? parts[1] : "")
        return Group {
            HStack(spacing: 10) {
                Text(type).font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                    .frame(width: 140, alignment: .leading)
                Text(payload.isEmpty ? "—" : payload).font(.caption.monospaced()).lineLimit(1)
                    .strikethrough(disabled)
                Spacer()
                Text(proxy).font(.caption).foregroundColor(disabled ? .secondary : M.accent)
            }
            .padding(.horizontal, 14).padding(.vertical, 6)
            .opacity(disabled ? 0.5 : 1)
            .contentShape(Rectangle())
            .contextMenu {
                if disabled {
                    Button { Task { await M.enableRule(rule) } } label: { Label("启用规则", systemImage: "checkmark.circle") }
                } else {
                    Button { Task { await M.disableRule(rule) } } label: { Label("禁用规则", systemImage: "xmark.circle") }
                    Button { editing = (idx, rule) } label: { Label("编辑规则…", systemImage: "pencil") }
                    Divider()
                    Button { move(idx, -1) } label: { Label("上移", systemImage: "chevron.up") }.disabled(idx == 0)
                    Button { move(idx, 1) } label: { Label("下移", systemImage: "chevron.down") }.disabled(idx == count - 1)
                    Divider()
                    Button(role: .destructive) { remove(idx) } label: { Label("删除规则", systemImage: "trash") }
                }
                Divider()
                Button { copyPB(payload) } label: { Label("复制内容", systemImage: "doc.on.doc") }
                Button { copyPB(rule) } label: { Label("复制规则", systemImage: "doc.on.clipboard") }
            }
            Divider().opacity(0.35)
        }
    }

    private func move(_ idx: Int, _ dir: Int) {
        var r = M.inlineRules; let j = idx + dir
        guard idx >= 0, j >= 0, idx < r.count, j < r.count else { return }
        r.swapAt(idx, j); Task { await M.applyRules(r) }
    }
    private func remove(_ idx: Int) {
        var r = M.inlineRules; guard idx >= 0, idx < r.count else { return }
        r.remove(at: idx); Task { await M.applyRules(r) }
    }
    private func copyPB(_ s: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string)
        M.showToast("已复制")
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
            PageHead(title: "实时日志", desc: "结构化日志流 · 核心运行状态") {
                Button { paused.toggle(); if paused { frozen = M.logs } } label: {
                    Label(paused ? "继续" : "暂停", systemImage: paused ? "play.fill" : "pause.fill")
                }.controlSize(.small)
                Button { exportLogs(rows) } label: { Label("导出", systemImage: "square.and.arrow.up") }
                    .controlSize(.small)
            }

            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                    TextField("过滤日志内容…", text: $q).textFieldStyle(.plain).frame(maxWidth: 200)
                }
                Picker("", selection: $level) {
                    Text("全部").tag("all"); Text("INFO").tag("info")
                    Text("WARN").tag("warning"); Text("ERROR").tag("error"); Text("DEBUG").tag("debug")
                }.pickerStyle(.segmented).frame(width: 300).labelsHidden()
                Spacer()
                HStack(spacing: 6) {
                    Circle().fill(paused ? Color.secondary : M.accent).frame(width: 6, height: 6)
                    Text("\(rows.count) 行").font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.3))
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
        VStack(spacing: 0) {
            PageHead(title: "DNS 缓存", desc: "内置 DNS 服务器 · Fake‑IP 映射与条目缓存分析") {
                Button { M.flushDnsCache() } label: { Label("刷新缓存", systemImage: "arrow.clockwise") }.controlSize(.small)
                Button { M.clearAllCache() } label: { Label("清空", systemImage: "trash") }.controlSize(.small)
            }

            ScrollView {
                VStack(spacing: 14) {
                    // DNS stats
                    HStack(spacing: 12) {
                        StatBox(label: "平均解析", value: "0.4", unit: "ms", sub: "DoH · 1.1.1.1")
                        StatBox(label: "Fake-IP 池", value: "198.18/15", sub: "已分配 1,204", accent: true)
                        StatBox(label: "缓存条目", value: "842", sub: "内存常驻")
                    }

                    // DNS settings (editable)
                    Card(title: "DNS 服务器", icon: "server.rack") {
                        VStack(spacing: 2) {
                            NToggle("启用 DNS", "dns", "enable")
                            NToggle("IPv6 解析", "dns", "ipv6")
                            NPicker("增强模式", "dns", "enhanced-mode", [("fake-ip","Fake-IP"),("redir-host","Redir-Host")])
                            NText("Fake-IP 段", "dns", "fake-ip-range", placeholder: "198.18.0.1/16")
                            NText("监听地址", "dns", "listen", placeholder: "0.0.0.0:53")
                            NList("上游 (nameserver)", "dns", "nameserver", placeholder: "https://1.1.1.1/dns-query")
                            NList("Fake-IP 过滤", "dns", "fake-ip-filter", placeholder: "*.lan")
                        }
                        Text("Fake-IP 为代理域名返回保留段虚拟 IP，避免 DNS 泄漏；上游支持 DoH/DoT/DoQ/UDP。")
                            .font(.system(size: 10)).foregroundColor(.secondary).padding(.top, 6)
                    }

                    Card(title: "DNS 解析测试", icon: "magnifyingglass") {
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
                                Text(result).font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
                                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }

                    // Fake-IP mappings observed in live connections
                    let fakeip = M.conns.filter { $0.dstIP.hasPrefix("198.18.") || $0.dstIP.hasPrefix("198.19.") }
                    Card(title: "Fake-IP 映射 · \(fakeip.count)（来自活跃连接）") {
                        if fakeip.isEmpty {
                            Text("当前无 Fake-IP 连接（需内核启用 dns.enhanced-mode: fake-ip 且有代理流量）")
                                .font(.system(size: 11)).foregroundColor(.secondary)
                        } else {
                            VStack(spacing: 4) {
                                ForEach(fakeip.prefix(50)) { c in
                                    HStack {
                                        Text(c.host).font(.system(size: 11)).lineLimit(1)
                                        Spacer()
                                        Text(c.dstIP).font(.system(size: 11, design: .monospaced)).foregroundColor(M.accent)
                                    }
                                }
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 20).padding(.bottom, 24)
            }
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

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

struct LinkLine: View {
    let start: CGPoint
    let end: CGPoint
    let color: Color
    @State private var phase: CGFloat = 0

    var body: some View {
        Path { path in
            path.move(to: start)
            let control1 = CGPoint(x: start.x + (end.x - start.x) * 0.5, y: start.y)
            let control2 = CGPoint(x: start.x + (end.x - start.x) * 0.5, y: end.y)
            path.addCurve(to: end, control1: control1, control2: control2)
        }
        .stroke(color.opacity(0.18), lineWidth: 1.5)
        .overlay(
            Path { path in
                path.move(to: start)
                let control1 = CGPoint(x: start.x + (end.x - start.x) * 0.5, y: start.y)
                let control2 = CGPoint(x: start.x + (end.x - start.x) * 0.5, y: end.y)
                path.addCurve(to: end, control1: control1, control2: control2)
            }
            .stroke(color, style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round, miterLimit: 0, dash: [6, 6], dashPhase: phase))
        )
        .onAppear {
            withAnimation(.linear(duration: 2.0).repeatForever(autoreverses: false)) {
                phase = -24
            }
        }
    }
}

struct SdwanTopologyView: View {
    @EnvironmentObject var M: AppModel
    let ifaces: [NetIface]
    let routes: [(dest: String, iface: String)]

    var body: some View {
        let activeIfaces = ifaces.filter { $0.isUp && !$0.ipv4.isEmpty }
        var dests = Array(Set(routes.map { $0.dest }))
        if dests.isEmpty {
            dests.append("0.0.0.0/0 (默认出口)")
        }

        return GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            let hostPt = CGPoint(x: 55, y: h / 2)

            let ifaceCount = max(1, activeIfaces.count)
            let ifacePoints = (0..<activeIfaces.count).map { idx -> (String, CGPoint) in
                let y = h / 2 + CGFloat(idx - (ifaceCount - 1) / 2) * 46
                return (activeIfaces[idx].id, CGPoint(x: w * 0.44, y: y))
            }

            let destCount = max(1, dests.count)
            let destPoints = (0..<dests.count).map { idx -> (String, CGPoint) in
                let y = h / 2 + CGFloat(idx - (destCount - 1) / 2) * 42
                return (dests[idx], CGPoint(x: w * 0.82, y: y))
            }

            ZStack {
                // Connections (Pan lines with flow simulation)
                ForEach(ifacePoints, id: \.0) { ifaceId, pt in
                    let color = lineColor(for: activeIfaces.first(where: { $0.id == ifaceId })?.kind ?? .physical)
                    LinkLine(start: hostPt, end: pt, color: color)
                }

                ForEach(routes.indices, id: \.self) { idx in
                    let r = routes[idx]
                    if let startPt = ifacePoints.first(where: { $0.0 == r.iface })?.1,
                       let endPt = destPoints.first(where: { $0.0 == r.dest })?.1 {
                        let color = lineColor(for: activeIfaces.first(where: { $0.id == r.iface })?.kind ?? .physical)
                        LinkLine(start: startPt, end: endPt, color: color)
                    }
                }

                if let eth = activeIfaces.first(where: { $0.kind == .physical }),
                   let ethPt = ifacePoints.first(where: { $0.0 == eth.id })?.1,
                   let defaultDestPt = destPoints.first(where: { $0.0.contains("0.0.0.0") || $0.0 == "default" })?.1 {
                    LinkLine(start: ethPt, end: defaultDestPt, color: .blue)
                }

                // Nodes
                VStack(spacing: 3) {
                    Image(systemName: "laptopcomputer").font(.system(size: 13))
                    Text("本机 (Host)").font(.system(size: 8, weight: .bold))
                }
                .frame(width: 66, height: 38)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .windowBackgroundColor)).opacity(0.85))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(M.accent, lineWidth: 1.2))
                .position(hostPt)

                ForEach(0..<activeIfaces.count, id: \.self) { idx in
                    let iface = activeIfaces[idx]
                    let pt = ifacePoints[idx].1
                    let color = lineColor(for: iface.kind)
                    HStack(spacing: 4) {
                        Image(systemName: iconName(for: iface.kind)).foregroundColor(color).font(.system(size: 10))
                        VStack(alignment: .leading, spacing: 0) {
                            Text(iface.name).font(.system(size: 9, design: .monospaced)).fontWeight(.bold)
                            Text(iface.primaryIP).font(.system(size: 7, design: .monospaced)).foregroundColor(.secondary)
                        }
                    }
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .windowBackgroundColor).opacity(0.85)))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(color.opacity(0.7), lineWidth: 1.0))
                    .position(pt)
                }

                ForEach(0..<dests.count, id: \.self) { idx in
                    let dest = dests[idx]
                    let pt = destPoints[idx].1
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.up.right.circle.fill").foregroundColor(.secondary).font(.system(size: 8))
                        Text(dest).font(.system(size: 8, design: .monospaced)).lineLimit(1)
                    }
                    .padding(.horizontal, 6).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .windowBackgroundColor).opacity(0.85)))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.1), lineWidth: 0.8))
                    .position(pt)
                }
            }
        }
        .frame(height: 200)
        .padding(10)
        .background(VisualEffectView(material: .underWindowBackground, blendingMode: .withinWindow).cornerRadius(12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.06)))
    }

    private func lineColor(for k: IfaceKind) -> Color {
        switch k {
        case .physical: return .blue
        case .proxyTun: return M.accent
        case .tailscale: return .teal
        case .zerotier: return .orange
        case .oray: return .purple
        default: return .secondary
        }
    }

    private func iconName(for k: IfaceKind) -> String {
        switch k {
        case .physical: return "wifi"
        case .proxyTun: return "shield.fill"
        case .tailscale: return "point.3.connected.trianglepath.dotted"
        case .zerotier: return "globe"
        case .oray: return "link"
        default: return "network"
        }
    }
}

struct SdwanPage: View {
    @EnvironmentObject var M: AppModel
    @State private var ifaces: [NetIface] = []
    @State private var routes: [(dest: String, iface: String)] = []

    private var sdwanCount: Int { ifaces.filter { $0.kind.sdwan }.count }
    private var hasDefaultViaTun: Bool { routes.contains { $0.dest == "default" } }

    var body: some View {
        VStack(spacing: 0) {
            PageHead(title: "SD-WAN 共存", desc: "网卡拓扑识别 · 路由冲突检测 · 多隧道并存分析") {
                Button { rescan() } label: { Label("重新扫描", systemImage: "arrow.clockwise") }.controlSize(.small)
            }

            ScrollView {
                VStack(spacing: 14) {
                    // status banner
                    HStack(spacing: 12) {
                        Image(systemName: "shield.lefthalf.filled").font(.title).foregroundColor(hasDefaultViaTun ? .orange : M.accent)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(hasDefaultViaTun ? "检测到 TUN 默认路由" : "智能路由隔离已生效").font(.system(size: 14, weight: .bold))
                            Text(hasDefaultViaTun
                                 ? "存在经 utun 的默认路由，可能与 SD-WAN 抢占。建议仅注入精确网段。"
                                 : "代理仅注入精确网段，未抢占默认路由；\(sdwanCount) 个 SD-WAN 接口路由保持完整。")
                                .font(.system(size: 11)).foregroundColor(.secondary)
                        }
                        Spacer()
                        VStack { Text("\(hasDefaultViaTun ? 1 : 0)").font(.system(size: 24, weight: .bold, design: .monospaced))
                                 .foregroundColor(hasDefaultViaTun ? .orange : M.accent)
                            Text("路由冲突").font(.system(size: 10)).foregroundColor(.secondary) }
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .windowBackgroundColor).opacity(0.5)))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.06)))

                    // Topology view of the network routing relation map
                    SdwanTopologyView(ifaces: ifaces, routes: routes)

                    // interfaces
                    Card(title: "网络接口拓扑 · \(ifaces.count)", icon: "network") {
                        VStack(spacing: 8) {
                            ForEach(ifaces) { i in ifaceRow(i) }
                            if ifaces.isEmpty { Text("正在扫描接口…").font(.system(size: 11)).foregroundColor(.secondary) }
                        }
                    }

                    // utun routes
                    Card(title: "UTUN 路由表 · \(routes.count)", icon: "list.bullet.indent") {
                        VStack(spacing: 4) {
                            if routes.isEmpty { Text("无 utun 路由").font(.system(size: 11)).foregroundColor(.secondary) }
                            ForEach(routes.indices, id: \.self) { idx in
                                HStack {
                                    Text(routes[idx].dest).font(.system(size: 11, design: .monospaced))
                                    Spacer()
                                    Image(systemName: "arrow.right").font(.system(size: 9)).foregroundColor(.secondary)
                                    Text(routes[idx].iface).font(.system(size: 11, design: .monospaced)).foregroundColor(M.accent)
                                }
                            }
                        }
                    }

                    Label("进程级分流 (SO_USER_COOKIE + PF) 与路由注入需特权 Helper（代码签名后于 v1.0 启用）",
                          systemImage: "lock.shield").font(.system(size: 10)).foregroundColor(.secondary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 20).padding(.bottom, 24)
            }
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
    @State private var editingID: String? = nil
    @State private var showImportRemote = false
    @State private var showAddLocal = false

    var body: some View {
        VStack(spacing: 0) {
            PageHead(title: "配置", desc: "本地 YAML 配置 · 远程订阅导入 · 一键切换并热重载") {
                Button { showImportRemote = true } label: { Label("导入订阅", systemImage: "icloud.and.arrow.down") }
                    .controlSize(.small)
                Button { showAddLocal = true } label: { Label("添加本地", systemImage: "doc.badge.plus") }
                    .controlSize(.small).tint(M.accent).buttonStyle(.borderedProminent)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if M.store.profiles.isEmpty {
                        ContentUnavailable("暂无配置，点击右上角“+”导入", "doc.text")
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 14)], spacing: 14) {
                        ForEach(M.store.profiles) { p in profileCard(p) }
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 24)
            }
        }
        .sheet(isPresented: $showImportRemote) { ImportRemoteSheet() }
        .sheet(isPresented: $showAddLocal) { AddLocalSheet() }
        .sheet(item: Binding(get: { editingID.map { IDBox(id: $0) } }, set: { editingID = $0?.id })) { box in
            ProfileEditSheet(profileID: box.id)
        }
    }

    struct IDBox: Identifiable { let id: String }

    private func profileCard(_ p: Profile) -> some View {
        let active = M.store.activeID == p.id
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: p.source == "remote" ? "icloud.fill" : "doc.fill")
                    .font(.system(size: 14))
                    .foregroundColor(active ? M.accent : .secondary)
                Text(p.name).font(.system(size: 14, weight: .bold)).lineLimit(1)
                Spacer()
                if active {
                    Text("生效中").font(.system(size: 10, weight: .bold)).foregroundColor(M.accent)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(M.accent.opacity(0.12)))
                } else {
                    Circle().stroke(Color.secondary.opacity(0.3), lineWidth: 1.5).frame(width: 12, height: 12)
                }
            }
            Text(p.source == "remote" ? "远程订阅" : "本地文件").font(.system(size: 10)).foregroundColor(.secondary)
            
            Divider().opacity(0.4).padding(.vertical, 2)
            
            HStack {
                Text(relTime(p.updatedAt)).font(.system(size: 10)).foregroundColor(.secondary)
                Spacer()
                if active {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(M.accent).font(.system(size: 14))
                } else {
                    Button("设为活动") { M.activateProfile(p.id) }
                        .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundColor(.accentColor)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .windowBackgroundColor).opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(active ? M.accent.opacity(0.4) : Color.primary.opacity(0.08), lineWidth: active ? 1.5 : 1))
        .contentShape(Rectangle())
        .onTapGesture { if !active { M.activateProfile(p.id) } }
        .contextMenu {
            if !active { Button { M.activateProfile(p.id) } label: { Label("设为活动", systemImage: "checkmark") } }
            Button { editingID = p.id } label: { Label("编辑 YAML…", systemImage: "pencil") }
            if p.source == "remote" {
                Button { Task { _ = await M.store.updateRemote(p.id); if active { M.activateProfile(p.id) }; M.showToast("已更新订阅") } } label: { Label("更新订阅", systemImage: "arrow.clockwise") }
            }
            Divider()
            Button(role: .destructive) { M.store.remove(p.id) } label: { Label("删除", systemImage: "trash") }
                .disabled(active)
        }
    }

    private func relTime(_ d: Date) -> String {
        let s = Int(Date().timeIntervalSince(d))
        if s < 60 { return "刚刚" }
        if s < 3600 { return "\(s/60) 分钟前" }
        if s < 86400 { return "\(s/3600) 小时前" }
        return "\(s/86400) 天前"
    }
}

// MARK: - Import / edit sheets

struct ImportRemoteSheet: View {
    @EnvironmentObject var M: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var name = ""; @State private var url = ""; @State private var busy = false; @State private var err = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("导入远程配置或订阅").font(.headline)
            TextField("名称", text: $name).textFieldStyle(.roundedBorder)
            TextField("https://…/clash 或订阅链接", text: $url).textFieldStyle(.roundedBorder).font(.callout.monospaced())
            if !err.isEmpty { Text(err).font(.caption).foregroundColor(.red) }
            HStack {
                Button("取消") { dismiss() }
                Spacer()
                Button { Task { await go() } } label: { if busy { ProgressView().controlSize(.small) } else { Text("导入") } }
                    .buttonStyle(.borderedProminent).disabled(url.isEmpty || busy)
            }
        }.padding(20).frame(width: 440)
    }
    private func go() async {
        busy = true; err = ""
        let nm = name.isEmpty ? (URL(string: url)?.host ?? "远程配置") : name
        if let id = await M.store.importRemote(name: nm, url: url) { M.activateProfile(id); dismiss() }
        else { err = "下载或解析失败，请检查链接" }
        busy = false
    }
}

struct AddLocalSheet: View {
    @EnvironmentObject var M: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var name = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("添加本地配置").font(.headline)
            TextField("名称", text: $name).textFieldStyle(.roundedBorder)
            HStack {
                Button("从文件导入…") { pickFile() }
                Spacer()
                Button("取消") { dismiss() }
            }
        }.padding(20).frame(width: 400)
    }
    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.yaml, .plainText]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url,
           url.startAccessingSecurityScopedResource(),
           let content = try? String(contentsOf: url, encoding: .utf8) {
            defer { url.stopAccessingSecurityScopedResource() }
            let nm = name.isEmpty ? url.deletingPathExtension().lastPathComponent : name
            let id = M.store.addLocal(name: nm, content: content)
            M.activateProfile(id); dismiss()
        }
    }
}

struct ProfileEditSheet: View {
    @EnvironmentObject var M: AppModel
    @Environment(\.dismiss) var dismiss
    let profileID: String
    @State private var text = ""
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("编辑配置").font(.headline)
                Spacer()
                Button("取消") { dismiss() }
                Button("保存并应用") {
                    M.store.saveContent(profileID, text)
                    if M.store.activeID == profileID { M.activateProfile(profileID) }
                    dismiss()
                }.buttonStyle(.borderedProminent)
            }.padding(14)
            Divider()
            YAMLEditor(text: $text, onChange: {})
        }
        .frame(width: 680, height: 560)
        .onAppear { text = M.store.content(profileID) }
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
        private var highlightTimer: Timer?
        init(_ p: YAMLEditor) { parent = p }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            parent.text = tv.string
            parent.onChange()
            scheduleHighlight()
        }

        /// Debounce highlight: wait 150ms of idle after the last keystroke
        /// before running the full regex pass. Prevents stutter on large files.
        private func scheduleHighlight() {
            highlightTimer?.invalidate()
            highlightTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
                self?.highlight()
            }
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

struct GeneralPage: View {
    @EnvironmentObject var M: AppModel
    @State private var host = ""
    @State private var port = ""
    @State private var secret = ""

    var body: some View {
        VStack(spacing: 0) {
            PageHead(title: "通用设置", desc: "连接参数 · 数据库更新 · 内核版本管理")

            ScrollView {
                VStack(spacing: 14) {
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
                        .font(.caption2).foregroundColor(.secondary).padding(.top, 6)
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
                        .font(.caption2).foregroundColor(.secondary).padding(.top, 6)
                }
                // GEO 下载源
                Card(title: "GEO 下载源", icon: "arrow.down.circle") {
                    VStack(spacing: 2) {
                        GeoURLRow("GeoIP", sub: "geoip")
                        GeoURLRow("GeoSite", sub: "geosite")
                        GeoURLRow("MMDB", sub: "mmdb")
                        GeoURLRow("ASN", sub: "asn")
                    }
                    Text("修改下载源 URL 后会在下次更新时生效。")
                        .font(.caption2).foregroundColor(.secondary).padding(.top, 6)
                }
                // 内核管理（版本 / 升级 / Alpha 切换 / 重启）
                KernelCard()
                Card(title: "外观", icon: "paintbrush") {
                    VStack(spacing: 10) {
                        Toggle("深色模式", isOn: $M.dark)
                        HStack {
                            Text("强调色").font(.caption); Spacer()
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
    }

    var statusLine: String {
        if !M.reachable { return "未连接内核" }
        return "已连接 · mihomo \(M.version)" + (M.engineManaged ? " · 引擎 \(M.engine.engineVersion)" : "")
    }
    var uptimeText: String {
        let s = M.engineUptime; let h = s / 3600; let m = (s % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m \(s % 60)s"
    }
    func field(_ l: String, text: Binding<String>, placeholder: String) -> some View {
        HStack { Text(l).font(.caption).foregroundColor(.secondary).frame(width: 50, alignment: .leading)
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder) }
    }
    func colorFor(_ s: String) -> Color { ["green":.green,"blue":.blue,"purple":.purple,"orange":.orange][s] ?? .green }
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
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, minHeight: 160).padding(40)
    }
}

// MARK: - Network / TUN / Sniffer (read-only in stage A; editable in C/E)

private func cfgStr(_ c: [String: Any], _ k: String) -> String { c[k].map { "\($0)" } ?? "—" }
private func cfgBool(_ c: [String: Any], _ k: String) -> Bool { (c[k] as? Bool) == true }

struct NetworkPage: View {
    @EnvironmentObject var M: AppModel
    var body: some View {
        VStack(spacing: 0) {
            PageHead(title: "网络入站", desc: "端口监听 · 局域网共享 · 访问控制列表 (ACL)")

            ScrollView {
                VStack(spacing: 14) {
                    Card(title: "入站端口", icon: "arrow.down.right.circle") {
                    VStack(spacing: 2) {
                        NumRow("HTTP 端口", key: "port")
                        NumRow("SOCKS 端口", key: "socks-port")
                        NumRow("混合端口", key: "mixed-port")
                        NumRow("Redir 端口", key: "redir-port")
                        NumRow("TProxy 端口", key: "tproxy-port")
                    }
                    Text("端口设为 0 即禁用。建议绝大多数应用使用混合端口（兼容 HTTP 与 SOCKS5）。")
                        .font(.caption2).foregroundColor(.secondary).padding(.top, 6)
                }
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
                        .font(.caption2).foregroundColor(.secondary).padding(.top, 6)
                }
                Card(title: "系统代理", icon: "globe.badge.chevron.backward") {
                    HStack {
                        Text("系统代理总开关").font(.caption)
                        Spacer()
                        Toggle("", isOn: Binding(get: { M.systemProxyOn }, set: { _ in M.toggleSystemProxy() }))
                            .toggleStyle(.switch).labelsHidden()
                    }
                    Text("开启后将本机 HTTP/HTTPS/SOCKS 系统代理指向 ClashPow（需特权 Helper，见“通用”页授权）。")
                        .font(.caption2).foregroundColor(.secondary).padding(.top, 6)
                }
                Spacer(minLength: 0)
            }.padding(18)
        }
    }
}

struct TunPage: View {
    @EnvironmentObject var M: AppModel
    var body: some View {
        VStack(spacing: 0) {
            PageHead(title: "TUN 模式", desc: "虚拟网卡驱动 · 协议栈选择 · 路由注入策略")

            ScrollView {
                VStack(spacing: 14) {
                    Card(title: "TUN 虚拟网卡", icon: "shield.lefthalf.filled") {
                    VStack(spacing: 2) {
                        HStack {
                            Text("启用 TUN").font(.callout); Spacer()
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
                        .font(.caption2).foregroundColor(.secondary).padding(.top, 6)
                }
                }
                Spacer(minLength: 0)
            }.padding(18)
        }
    }
}

struct SnifferPage: View {
    @EnvironmentObject var M: AppModel
    var body: some View {
        VStack(spacing: 0) {
            PageHead(title: "流量嗅探", desc: "协议解析 (TLS/HTTP/QUIC) · 真实域名还原")

            ScrollView {
                VStack(spacing: 14) {
                    Card(title: "协议嗅探 Sniffer", icon: "scope") {
                    VStack(spacing: 2) {
                        NToggle("启用嗅探", "sniffer", "enable")
                        NToggle("覆盖目标地址", "sniffer", "override-destination")
                        NToggle("强制 DNS 映射", "sniffer", "force-dns-mapping")
                    }
                    Text("从 TLS / QUIC / HTTP 握手中提取真实域名用于分流，对走 IP 的连接尤为重要。")
                        .font(.caption2).foregroundColor(.secondary).padding(.top, 6)
                }
                }
                Spacer(minLength: 0)
            }.padding(18)
        }
    }
}

private func kvRow(_ l: String, _ v: String) -> some View {
    HStack { Text(l).font(.caption); Spacer(); Text(v).font(.caption.monospaced()).foregroundColor(.secondary) }
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
            Text(label).font(.callout)
            Spacer()
            TextField("0", text: $text)
                .textFieldStyle(.roundedBorder).frame(width: 90)
                .font(.callout.monospaced()).multilineTextAlignment(.trailing)
                .onSubmit { commit() }
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
            Text(label).font(.callout)
            Spacer()
            Toggle("", isOn: Binding(
                get: { (M.configs[key] as? Bool) == true },
                set: { v in Task { await M.patch([key: v]) } }
            )).toggleStyle(.switch).labelsHidden()
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
            Text(label).font(.callout)
            Spacer()
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder).frame(width: 160)
                .font(.callout.monospaced()).multilineTextAlignment(.trailing)
                .onSubmit { Task { await M.patch([key: text]) } }
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
            Text(label).font(.callout)
            Spacer()
            Picker("", selection: Binding(
                get: { (M.configs[key] as? String) ?? options.first?.0 ?? "" },
                set: { v in Task { await M.patch([key: v]) } }
            )) {
                ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
            }.labelsHidden().frame(width: 150)
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
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.callout)
            ForEach(items.indices, id: \.self) { i in
                HStack {
                    Text(items[i]).font(.caption.monospaced()).foregroundColor(.secondary)
                    Spacer()
                    Button { items.remove(at: i); commit() } label: { Image(systemName: "minus.circle").font(.caption) }
                        .buttonStyle(.borderless)
                }
            }
            HStack {
                TextField(placeholder, text: $draft)
                    .textFieldStyle(.roundedBorder).font(.caption.monospaced())
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(!draftValid ? Color.red.opacity(0.7) : Color.clear, lineWidth: 1))
                Button { if !draft.isEmpty && draftValid { items.append(draft); draft = ""; commit() } } label: { Image(systemName: "plus.circle.fill") }
                    .buttonStyle(.borderless).disabled(!draftValid || draft.isEmpty)
            }
            if !draftValid {
                Text("格式无效 — 请检查输入（如 IP/CIDR: 10.0.0.0/8, URL: https://...）")
                    .font(.system(size: 9)).foregroundColor(.red)
            }
        }
        .padding(.vertical, 5)
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

/// GEO download-source URL row (nested under geox-url.<sub>).
struct GeoURLRow: View {
    @EnvironmentObject var M: AppModel
    let label: String; let sub: String
    init(_ label: String, sub: String) { self.label = label; self.sub = sub }
    @State private var text = ""
    var body: some View {
        HStack {
            Text(label).font(.callout).frame(width: 70, alignment: .leading)
            TextField("https://…", text: $text)
                .textFieldStyle(.roundedBorder).font(.system(size: 10, design: .monospaced))
                .onSubmit { Task { await M.patch(["geox-url": [sub: text]]) } }
        }
        .padding(.vertical, 5)
        .onAppear {
            let geo = M.configs["geox-url"] as? [String: Any] ?? [:]
            text = (geo[sub] as? String) ?? ""
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
            Text(label).font(.callout); Spacer()
            Toggle("", isOn: Binding(
                get: { (nestedDict(M, parent)[sub] as? Bool) == true },
                set: { v in Task { await M.patch([parent: [sub: v]]) } }
            )).toggleStyle(.switch).labelsHidden()
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
            Text(label).font(.callout); Spacer()
            Picker("", selection: Binding(
                get: { (nestedDict(M, parent)[sub] as? String) ?? options.first?.0 ?? "" },
                set: { v in Task { await M.patch([parent: [sub: v]]) } }
            )) { ForEach(options, id: \.0) { Text($0.1).tag($0.0) } }.labelsHidden().frame(width: 150)
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
            Text(label).font(.callout); Spacer()
            TextField(placeholder, text: $text).textFieldStyle(.roundedBorder).frame(width: 180)
                .font(.callout.monospaced()).multilineTextAlignment(.trailing)
                .onSubmit { Task { await M.patch([parent: [sub: text]]) } }
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
        VStack(alignment: .leading, spacing: 5) {
            Text(label).font(.callout)
            ForEach(items.indices, id: \.self) { i in
                HStack {
                    Text(items[i]).font(.caption.monospaced()).foregroundColor(.secondary); Spacer()
                    Button { items.remove(at: i); commit() } label: { Image(systemName: "minus.circle").font(.caption) }.buttonStyle(.borderless)
                }
            }
            HStack {
                TextField(placeholder, text: $draft).textFieldStyle(.roundedBorder).font(.caption.monospaced())
                Button { if !draft.isEmpty { items.append(draft); draft = ""; commit() } } label: { Image(systemName: "plus.circle.fill") }.buttonStyle(.borderless)
            }
        }.padding(.vertical, 5)
        .onAppear { items = (nestedDict(M, parent)[sub] as? [Any])?.map { "\($0)" } ?? [] }
    }
    private func commit() { Task { await M.patch([parent: [sub: items]]) } }
}

// MARK: - Rule editor sheet

struct RuleEditSheet: View {
    let title: String
    @State var text: String
    let onSave: (String) -> Void
    let onCancel: () -> Void
    init(title: String, initial: String, onSave: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self.title = title; self._text = State(initialValue: initial); self.onSave = onSave; self.onCancel = onCancel
    }
    var body: some View {
        VStack(spacing: 14) {
            Text(title).font(.headline)
            TextField("DOMAIN-SUFFIX,example.com,Proxy", text: $text)
                .textFieldStyle(.roundedBorder).font(.callout.monospaced()).frame(width: 360)
            Text("格式：类型,内容,策略[,参数]  例如 IP-CIDR,10.0.0.0/8,DIRECT,no-resolve")
                .font(.caption2).foregroundColor(.secondary)
            HStack {
                Button("取消") { onCancel() }
                Spacer()
                Button("保存") { onSave(text) }.buttonStyle(.borderedProminent).disabled(text.isEmpty)
            }
        }.padding(20).frame(width: 420)
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
                    Text(M.reachable ? "运行中 · mihomo \(M.version)" : "未连接").font(.caption).foregroundColor(.secondary)
                    Spacer()
                    if M.engineManaged {
                        Button("重启内核", systemImage: "arrow.triangle.2.circlepath") {
                            Task { await M.engine.restart(); try? await Task.sleep(nanoseconds: 3_000_000_000); await M.reconnect(); M.showToast("内核已重启") }
                        }.buttonStyle(.bordered).tint(.orange).controlSize(.small)
                    }
                }
                Divider()
                HStack {
                    Text("更新通道").font(.caption)
                    Spacer()
                    Picker("", selection: $km.channel) {
                        Text("正式版").tag("stable"); Text("Alpha").tag("alpha")
                    }.pickerStyle(.segmented).frame(width: 160).labelsHidden()
                }
                HStack {
                    if km.checking { ProgressView().controlSize(.small) }
                    else if !km.latestTag.isEmpty {
                        Text("最新：\(km.latestTag)").font(.caption.monospaced()).foregroundColor(.secondary)
                    } else {
                        Text("点击检查可用内核版本").font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("检查更新") { Task { await km.check() } }.controlSize(.small).disabled(km.checking)
                    if !km.assetURL.isEmpty {
                        Button {
                            Task { await km.download() }
                        } label: {
                            if km.downloading { ProgressView().controlSize(.small) } else { Text("下载 \(km.channel == "alpha" ? "Alpha" : "正式版")") }
                        }.controlSize(.small).buttonStyle(.borderedProminent).tint(M.accent).disabled(km.downloading)
                    }
                }
                if !km.installedTags.isEmpty {
                    Divider()
                    HStack {
                        Text("运行内核").font(.caption); Spacer()
                        if km.activeTag.isEmpty {
                            Text("内嵌").font(.caption2).padding(.horizontal, 6).padding(.vertical, 1)
                                .background(Capsule().fill(M.accent.opacity(0.15))).foregroundColor(M.accent)
                        } else {
                            Button("切回内嵌内核") { Task { await km.useEmbedded(); try? await Task.sleep(nanoseconds: 3_500_000_000); await M.reconnect() } }
                                .controlSize(.small)
                        }
                    }
                    ForEach(km.installedTags, id: \.self) { tag in
                        HStack {
                            Image(systemName: "shippingbox").font(.caption2).foregroundColor(.secondary)
                            Text(tag).font(.caption.monospaced())
                            Spacer()
                            if km.activeTag == tag {
                                Label("使用中", systemImage: "checkmark.circle.fill").font(.caption2).foregroundColor(M.accent)
                            } else {
                                Button("启用") { Task { await km.activate(tag); try? await Task.sleep(nanoseconds: 3_500_000_000); await M.reconnect() } }
                                    .controlSize(.small)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                if !km.note.isEmpty { Text(km.note).font(.caption2).foregroundColor(.secondary).frame(maxWidth: .infinity, alignment: .leading) }
                Text("下载源 MetaCubeX/mihomo releases。启用下载内核后，引擎以监管进程模式运行该外部内核；可随时切回内嵌内核。")
                    .font(.caption2).foregroundColor(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear { km.scanInstalled() }
    }
}
