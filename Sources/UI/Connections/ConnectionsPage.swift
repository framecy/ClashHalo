import SwiftUI

struct ConnectionsPage: View {
    @EnvironmentObject var M: AppModel
    @StateObject private var VM = ConnectionsViewModel()
    @State private var q = ""
    @State private var showConfirmDisconnect = false
    @State private var selectedTab = 0

    struct RuleEditContext: Identifiable {
        let id = UUID()
        let node: RuleNode?
        let conn: Conn
    }

    /// Domain-aggregated row for "聚合" view: folds every active Conn sharing
    /// the same host into one expandable row. Useful when a single backend
    /// (e.g. gateway.icloud.com) opens dozens of independent sessions — one
    /// collapsed row surfaces "who keeps phoning home" cleanly.
    struct ConnGroup: Identifiable {
        let id: String          // host, falls back to dstIP
        var host: String
        var dstIPHint: String   // representative IP:port from first member
        var processes: String   // joined unique processes (top 2 + "+N")
        var rule: String        // representative rule of max-rate member
        var chain: String       // representative chain
        var count: Int
        var isDirect: Bool
        var upRate: Int64
        var downRate: Int64
        var upTotal: Int64
        var downTotal: Int64
        var members: [Conn]    // sorted by combined rate desc
    }

    // Sort & Selection
    @State private var sortOrder = [KeyPathComparator(\Conn.downRate, order: .reverse)]
    @State private var selection: Conn.ID? = nil

    // Rule Editor
    @StateObject private var ruleModel = RuleEditorModel(targetFilePath: "")
    @State private var activeRuleEdit: RuleEditContext? = nil

    // Cached filter/sort — recompute only when inputs change (not every body pass).
    @State private var filteredRows: [Conn] = []
    @State private var filterFingerprint: String = ""

    private func recomputeFilteredRowsIfNeeded() {
        let source = selectedTab == 0 ? VM.conns : VM.closedConnections
        // Fingerprint source identity + query + tab + sort keys. Conn is Equatable;
        // using count + first/last id + rate sum is a cheap churn detector.
        let rateSum = source.reduce(into: Int64(0)) { $0 += $1.downRate &+ $1.upRate }
        let head = source.first?.id ?? "-"
        let tail = source.last?.id ?? "-"
        let sortKey = sortOrder.map { "\($0.keyPath):\($0.order == .forward ? "f" : "r")" }.joined(separator: ",")
        let fp = "\(selectedTab)|\(q)|\(source.count)|\(head)|\(tail)|\(rateSum)|\(sortKey)"
        guard fp != filterFingerprint else { return }
        filterFingerprint = fp
        filteredRows = source.filter { matches($0) }.sorted(using: sortOrder)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: DS.Spacing.m) {
                DSSegmentedControl(selection: $selectedTab, choices: [
                    DSChoice("连接中", 0),
                    DSChoice("已关闭", 1),
                    DSChoice("聚合", 2)
                ])
                .frame(width: 232)

                HStack(spacing: DS.Spacing.s) {
                    Image(systemName: "magnifyingglass").foregroundColor(.secondary).font(.dsBody)
                    TextField("搜索域名 / 进程 / 规则", text: $q)
                        .textFieldStyle(.plain)
                        .font(.dsBody)
                }
                .dsSearchFieldChrome(maxWidth: 280)

                // Capability boundary: in system-proxy mode the stats below
                // only cover traffic that actually entered mihomo. Apps that
                // ignore proxy settings, UDP/QUIC and bypass-list hosts stay
                // direct and invisible here — say so exactly when that mode
                // is active, instead of letting a "smaller than expected"
                // number read as a broken counter.
                if M.systemProxyOn && !M.tunOn {
                    Text("仅统计进入 mihomo 的连接")
                        .font(.dsCaption).foregroundColor(.secondary)
                        .help("系统代理模式下，不遵守代理设置的应用、UDP/QUIC 与绕过列表流量不经过内核，不计入本页统计。开启 TUN 可获得更完整的接管与统计。")
                }

                Spacer(minLength: 0)

                Text("\(filteredRows.count) 匹配").font(.dsBody).foregroundColor(.secondary)

                Button(role: .destructive) { showConfirmDisconnect = true } label: {
                    Label("全部断开", systemImage: "xmark.circle")
                }
                .dsButton(.destructive)

            }
            .padding(.horizontal, DS.Layout.pageContentInset)
            .padding(.vertical, DS.Spacing.m)
            .frame(height: DS.Layout.chromeHeight, alignment: .center)
            .background(DS.Palette.chromeBg)
            Divider().overlay(DS.Palette.separator)

            if selectedTab == 2 {
                ConnAggregateView(
                    groups: aggregateGroups(),
                    query: q,
                    onDisconnectOne: { id in M.closeConnection(id: id) },
                    onDisconnectHost: { host in M.closeConnections(host: host) },
                    onPrepareRuleEdit: prepareRuleEdit(for:)
                )
            } else if filteredRows.isEmpty {
                ContentUnavailable(
                    q.isEmpty
                        ? (selectedTab == 0 ? "暂无活跃连接" : "暂无已关闭连接")
                        : "无匹配结果",
                    "point.3.connected.trianglepath.dotted"
                )
                .onTapGesture { selection = nil }
            } else {
                Table(filteredRows, selection: $selection, sortOrder: $sortOrder) {
                    TableColumn("目标", value: \.host) { c in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(c.host).font(.dsBodyMedium).lineLimit(1)
                            Text("\(c.dstIP):\(c.port)").font(.dsMono).foregroundColor(.secondary).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }.width(min: 180, ideal: 240)
                    TableColumn("进程", value: \.process) { c in
                        Text(c.process).font(.dsBody).foregroundColor(.secondary).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.width(min: 80, ideal: 120)
                    TableColumn("规则", value: \.rule) { c in
                        Text(c.rule).font(.dsMono).foregroundColor(.secondary).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.width(min: 100, ideal: 150)
                    TableColumn("链路", value: \.chain) { c in
                        HStack(spacing: 4) {
                            Text(c.chain).font(.dsBodySemibold).foregroundColor(c.category == "proxy" ? DS.Palette.accent : .secondary).lineLimit(1)
                            Text(c.node).font(.dsMono).foregroundColor(.secondary).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }.width(min: 120, ideal: 180)
                    TableColumn("↓", value: \.downRate) { c in
                        Text(fmtRate(Double(c.downRate))).font(.dsMono)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.width(70)
                    TableColumn("↑", value: \.upRate) { c in
                        Text(fmtRate(Double(c.upRate))).font(.dsMono).foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.width(70)
                    TableColumn("") { c in
                        if selectedTab == 0 {
                            Button { M.closeConnection(id: c.id) } label: { Image(systemName: "xmark.circle") }
                                .buttonStyle(.borderless).foregroundColor(.secondary).help("断开此连接")
                        }
                    }.width(36)
                }
                // Lock table content inset to the same token as the toolbar strip.
                .contentMargins(.horizontal, DS.Layout.pageContentInset, for: .scrollContent)
                .contextMenu(forSelectionType: Conn.ID.self) { ids in
                    if let id = ids.first, let c = filteredRows.first(where: { $0.id == id }) {
                        Button("添加/修改分流规则...") {
                            prepareRuleEdit(for: c)
                        }
                        if selectedTab == 0 {
                            Divider()
                            Button("断开连接", role: .destructive) {
                                M.closeConnection(id: c.id)
                            }
                        }
                    }
                }
            }
        }
        .onAppear {
            VM.start()
            recomputeFilteredRowsIfNeeded()
            if !M.engine.configFilePath.isEmpty {
                ruleModel.setTargetPath(M.engine.configFilePath)
                ruleModel.load()
            }
        }
        .onDisappear {
            VM.stop()
            filteredRows = []
            filterFingerprint = ""
        }
        .onChange(of: M.engine.configFilePath) { _, path in
            if !path.isEmpty {
                ruleModel.setTargetPath(path)
                ruleModel.load()
            }
        }
        .onChange(of: selectedTab) { _, _ in recomputeFilteredRowsIfNeeded() }
        .onChange(of: q) { _, _ in recomputeFilteredRowsIfNeeded() }
        .onChange(of: sortOrder) { _, _ in recomputeFilteredRowsIfNeeded() }
        .onChange(of: VM.conns) { _, _ in recomputeFilteredRowsIfNeeded() }
        .onChange(of: VM.closedConnections) { _, _ in recomputeFilteredRowsIfNeeded() }
        .overlay(alignment: .bottomTrailing) {
            if let id = selection, let c = (VM.conns + VM.closedConnections).first(where: { $0.id == id }) {
                ConnDetailCard(conn: c) { selection = nil }
                    .padding()
            }
        }
        .confirmationDialog("确定要断开所有连接吗？", isPresented: $showConfirmDisconnect, titleVisibility: .visible) {
            Button("确定断开", role: .destructive) { M.closeAllConnections() }
        } message: {
            Text("这将中断所有正在进行的网络会话")
        }
        .sheet(item: $activeRuleEdit) { ctx in
            RuleFormView(existingNode: ctx.node, proxyGroups: M.groups.map { $0.name }, contextConn: ctx.conn) { newNode in
                if let old = ctx.node, ruleModel.nodes.contains(where: { $0.id == old.id }) {
                    ruleModel.updateNode(id: old.id, with: newNode)
                } else {
                    ruleModel.addNode(newNode)
                }

                // Transactional path (backup + reload + rollback on failure) —
                // the previous direct `ruleModel.save()` + reload had no
                // validation and no rollback, diverging from RulesPage.
                M.applyRuleEditorSave(save: { ruleModel.save() }) { ok in
                    if ok {
                        M.closeConnection(id: ctx.conn.id)
                    }
                }
            }
        }
    }

    private func matches(_ c: Conn) -> Bool {
        q.isEmpty
            || c.host.localizedCaseInsensitiveContains(q)
            || c.process.localizedCaseInsensitiveContains(q)
            || c.chain.localizedCaseInsensitiveContains(q)
            || c.rule.localizedCaseInsensitiveContains(q)
    }

    private func prepareRuleEdit(for c: Conn) {
        let parts = c.rule.components(separatedBy: ",")
        var matchedExisting: RuleNode? = nil

        let rType = parts.count >= 1 ? parts[0] : ""
        let rMatch = parts.count >= 2 ? parts[1] : ""

        if parts.count >= 2 {
            if let existing = ruleModel.nodes.first(where: { $0.type.rawValue == rType && $0.match == rMatch }) {
                matchedExisting = existing
            }
        }

        var finalNode: RuleNode
        if let existing = matchedExisting {
            finalNode = existing
        } else {
            var type: MihomoRuleType
            var match: String

            if let parsedType = MihomoRuleType(rawValue: rType) {
                type = parsedType
                switch type {
                case .domain, .domainSuffix, .domainKeyword, .domainWildcard, .domainRegex:
                    match = c.host != c.dstIP ? c.host : c.dstIP
                case .ipCidr, .ipCidr6, .ipSuffix, .ipAsn:
                    match = "\(c.dstIP)/32"
                case .srcIpCidr:
                    match = "\(c.srcIP)/32"
                case .port, .dstPort, .inPort:
                    match = c.port
                case .srcPort:
                    match = "" // Fallback
                case .processPath:
                    let rawPath = c.processPath != "—" && !c.processPath.isEmpty ? c.processPath : c.process
                    match = rawPath != "—" ? rawPath : ""
                case .processName, .processNameWildcard, .processNameRegex:
                    let raw = c.process != "—" ? c.process : ""
                    match = (raw as NSString).lastPathComponent
                case .network:
                    match = c.network
                case .geosite, .geoip, .srcGeoip, .dscp, .ruleSet, .subRule, .match:
                    // For these types, it's usually better to create a direct rule for the host/ip
                    let isIP = c.host == c.dstIP
                    type = isIP ? .ipCidr : .domainSuffix
                    match = isIP ? "\(c.dstIP)/32" : c.host
                }
            } else {
                let isIP = c.host == c.dstIP
                type = isIP ? .ipCidr : .domainSuffix
                match = isIP ? "\(c.dstIP)/32" : c.host
            }

            finalNode = RuleNode(type: type, match: match, action: .proxy, sort: 0, proxyGroup: c.group, note: c.process != "—" ? c.process : "")
        }

        activeRuleEdit = RuleEditContext(node: finalNode, conn: c)
    }

    /// Build domain-aggregated groups from the *active* connections only —
    /// closed conns are already transient (zero rate) and would just add noise.
    /// Groups are keyed by `host` (falling back to `dstIP` for raw-IP traffic)
    /// and sorted by combined rate descending so the busiest domain floats up.
    private func aggregateGroups() -> [ConnGroup] {
        var map: [String: ConnGroup] = [:]
        for c in VM.conns {
            let key = c.host.isEmpty ? c.dstIP : c.host
            let isDirect = c.category == "direct"
            if var g = map[key] {
                g.count += 1
                g.upRate += max(0, c.upRate)
                g.downRate += max(0, c.downRate)
                g.upTotal += c.up
                g.downTotal += c.down
                g.members.append(c)
                map[key] = g
            } else {
                map[key] = ConnGroup(
                    id: key,
                    host: key,
                    dstIPHint: "\(c.dstIP):\(c.port)",
                    processes: c.process,
                    rule: c.rule,
                    chain: c.chain,
                    count: 1,
                    isDirect: isDirect,
                    upRate: max(0, c.upRate),
                    downRate: max(0, c.downRate),
                    upTotal: c.up,
                    downTotal: c.down,
                    members: [c]
                )
            }
        }
        var groups = Array(map.values)
        // Recompute representative fields from the hottest member of each group.
        for i in groups.indices {
            let sorted = groups[i].members.sorted { $0.downRate + $0.upRate > $1.downRate + $1.upRate }
            groups[i].members = sorted
            if let hot = sorted.first {
                groups[i].dstIPHint = "\(hot.dstIP):\(hot.port)"
                groups[i].rule = hot.rule
                groups[i].chain = hot.chain
            }
            // Summarise processes: up to 2 unique names then "+N more".
            let unique = Array(Set(groups[i].members.map { $0.process })).filter { $0 != "—" }
            if unique.count <= 2 {
                groups[i].processes = unique.joined(separator: ", ")
            } else {
                groups[i].processes = "\(unique.prefix(2).joined(separator: ", ")) (+\(unique.count - 2))"
            }
        }
        // Apply text filter (host / processes / chain / rule).
        let query = q.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            groups = groups.filter { g in
                g.host.localizedCaseInsensitiveContains(query)
                    || g.processes.localizedCaseInsensitiveContains(query)
                    || g.chain.localizedCaseInsensitiveContains(query)
                    || g.rule.localizedCaseInsensitiveContains(query)
            }
        }
        groups.sort { lhs, rhs in
            (lhs.downRate + lhs.upRate, lhs.count) > (rhs.downRate + rhs.upRate, rhs.count)
        }
        return groups
    }
}

// MARK: - Aggregate View (per-host collapse)
struct ConnAggregateView: View {
    let groups: [ConnectionsPage.ConnGroup]
    let query: String
    let onDisconnectOne: (String) -> Void
    let onDisconnectHost: (String) -> Void
    let onPrepareRuleEdit: (Conn) -> Void

    @State private var expanded: Set<String> = []

    var body: some View {
        if groups.isEmpty {
            ContentUnavailable(
                query.isEmpty ? "暂无活跃连接" : "无匹配结果",
                "point.3.connected.trianglepath.dotted"
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(groups) { g in
                        VStack(spacing: 0) {
                            groupHeader(g)
                            if expanded.contains(g.id) {
                                // Inline member rows — not a Table, to keep things
                                // compact and avoid a second scroll surface.
                                VStack(spacing: 0) {
                                    ForEach(g.members) { c in
                                        memberRow(c, inGroup: g)
                                        if c.id != g.members.last?.id {
                                            Rectangle().fill(DS.Palette.separator).frame(height: 0.5)
                                        }
                                    }
                                }
                                .background(DS.Palette.cardBg)
                                .overlay(alignment: .leading) {
                                    Rectangle().fill(DS.Palette.accent).frame(width: 2)
                                }
                            }
                            Rectangle().fill(DS.Palette.separator).frame(height: 0.5)
                        }
                    }
                }
                .padding(.horizontal, DS.Layout.pageContentInset)
                .padding(.vertical, DS.Spacing.s)
            }
        }
    }

    private func groupHeader(_ g: ConnectionsPage.ConnGroup) -> some View {
        HStack(spacing: DS.Spacing.m) {
            Button {
                if #available(macOS 14.0, *) {
                    withAnimation(DS.Motion.micro) {
                        if expanded.contains(g.id) { expanded.remove(g.id) } else { expanded.insert(g.id) }
                    }
                } else {
                    if expanded.contains(g.id) { expanded.remove(g.id) } else { expanded.insert(g.id) }
                }
            } label: {
                HStack(spacing: DS.Spacing.xs) {
                    Image(systemName: expanded.contains(g.id) ? "chevron.down" : "chevron.right")
                        .font(.dsBody)
                        .foregroundColor(.secondary)
                        .frame(width: 14)
                    Text(g.host)
                        .font(.dsBodyMedium)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .buttonStyle(.plain)

            // Connection count pill — a near-1 entry shows nothing, dozens show
            // immediately why this row exists.
            if g.count > 1 {
                Text("\(g.count)")
                    .font(.dsMono)
                    .foregroundColor(.white)
                    .padding(.horizontal, DS.Spacing.s)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(DS.Palette.accent.opacity(0.85)))
            }

            Spacer(minLength: 0)

            Text(g.processes)
                .font(.dsBody)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 220, alignment: .trailing)

            // Rule badge
            Text(g.rule)
                .font(.dsMono)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 140, alignment: .leading)

            // Chain
            HStack(spacing: DS.Spacing.xs) {
                Text(g.chain)
                    .font(.dsBodySemibold)
                    .foregroundColor(g.isDirect ? .secondary : DS.Palette.accent)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: 160, alignment: .leading)

            // Aggregate rates
            Text(fmtRate(Double(g.downRate))).font(.dsMono)
                .frame(width: 70, alignment: .leading)
            Text(fmtRate(Double(g.upRate))).font(.dsMono)
                .foregroundColor(.secondary)
                .frame(width: 70, alignment: .leading)

            // Row-level actions
            Menu {
                Button("断开该域名全部", role: .destructive) { onDisconnectHost(g.host) }
                Button("添加/修改分流规则...") { onPrepareRuleEdit(g.members.first!) }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .foregroundColor(.secondary)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 28)
        }
        .padding(.horizontal, DS.Spacing.s)
        .padding(.vertical, DS.Spacing.s)
        .contentShape(Rectangle())
        .background(DS.Palette.windowBg)
    }

    private func memberRow(_ c: Conn, inGroup g: ConnectionsPage.ConnGroup) -> some View {
        HStack(spacing: DS.Spacing.m) {
            Text("")
                .frame(width: 14) // indent under chevron column
            Text("\(c.dstIP):\(c.port)")
                .font(.dsMono)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Text(c.process)
                .font(.dsBody)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 160, alignment: .trailing)
            Text(c.rule)
                .font(.dsMono)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 140, alignment: .leading)
            Text(c.chain)
                .font(.dsMono)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 160, alignment: .leading)
            Text(fmtRate(Double(c.downRate))).font(.dsMono)
                .frame(width: 70, alignment: .leading)
            Text(fmtRate(Double(c.upRate))).font(.dsMono)
                .foregroundColor(.secondary)
                .frame(width: 70, alignment: .leading)
            Button { onDisconnectOne(c.id) } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.borderless)
            .foregroundColor(.secondary)
            .help("断开此连接")
            .frame(width: 28)
        }
        .padding(.horizontal, DS.Spacing.s)
        .padding(.vertical, DS.Spacing.xs)
    }
}

// MARK: - Conn Detail Popup
struct ConnDetailCard: View {
    let conn: Conn
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.m) {
            HStack {
                Label("连接详情", systemImage: "info.circle.fill")
                    .font(.dsSection)
                    .foregroundColor(.primary)
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark.circle.fill").foregroundColor(.secondary) }
                    .buttonStyle(.plain)
            }

            Divider()

            Grid(alignment: .leading, horizontalSpacing: DS.Spacing.l, verticalSpacing: DS.Spacing.s) {
                GridRow { Text("ID").foregroundColor(.secondary); Text(conn.id).font(.dsMono).lineLimit(1).truncationMode(.middle) }
                GridRow { Text("目标域名").foregroundColor(.secondary); Text(conn.host).font(.dsBodyMedium).textSelection(.enabled) }
                GridRow { Text("目标 IP").foregroundColor(.secondary); Text("\(conn.dstIP):\(conn.port)").font(.dsMono).textSelection(.enabled) }
                GridRow { Text("源 IP").foregroundColor(.secondary); Text(conn.srcIP).font(.dsMono).textSelection(.enabled) }
                GridRow { Text("网络类型").foregroundColor(.secondary); Text(conn.network).font(.dsMono) }
                GridRow { Text("触发进程").foregroundColor(.secondary); Text(conn.process).font(.dsBodyMedium).textSelection(.enabled) }
                GridRow { Text("匹配规则").foregroundColor(.secondary); Text(conn.rule).font(.dsMono).textSelection(.enabled) }
                GridRow { Text("命中策略").foregroundColor(.secondary); Text(conn.group).font(.dsBodySemibold) }
                GridRow { Text("代理节点").foregroundColor(.secondary); Text(conn.node).font(.dsBodyMedium) }
                GridRow { Text("总上传").foregroundColor(.secondary); Text(fmtBytes(Double(conn.up))).font(.dsMono) }
                GridRow { Text("总下载").foregroundColor(.secondary); Text(fmtBytes(Double(conn.down))).font(.dsMono) }
                GridRow { Text("连接时间").foregroundColor(.secondary); Text(formatStartTime(conn.start)).font(.dsMono) }
            }
            .font(.dsBody)
        }
        .padding(DS.Spacing.xl)
        .frame(width: 340)
        .background(DS.Palette.overlayBg)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                .stroke(DS.Palette.border, lineWidth: 1)
        )
        .shadow(color: DS.Palette.cardShadowContact, radius: 2, x: 0, y: 1)
        .shadow(color: DS.Palette.cardShadow, radius: 20, x: 0, y: 8)
    }

    private func formatStartTime(_ isoString: String) -> String {
        let formatter = Self.isoFormatter
        if let date = formatter.date(from: isoString) {
            return Self.displayFormatter.string(from: date)
        }
        return String(isoString.prefix(19)).replacingOccurrences(of: "T", with: " ")
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let displayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
}


@MainActor final class ConnectionsViewModel: ObservableObject {
    @Published var conns: [Conn] = []
    @Published var closedConnections: [Conn] = []

    private var wsHandle: WSHandle?
    private var fallbackTimer: Timer?
    private let api = MihomoClient.shared
    private let M = AppModel.shared

    /// Fingerprint of the last decoded payload — when mihomo pushes the same
    /// snapshot twice (common on WS, which fires on state-change not on a
    /// fixed cadence), the second message is identical bytes. Skip the full
    /// decode of thousands of connection objects entirely.
    private var lastPayloadFingerprint: UInt64 = 0

    /// Previous-frame Conn by id — used for incremental diff so we don't
    /// rebuild 14 strings per connection when only the byte counters changed.
    private var prevConnById: [String: Conn] = [:]

    func start() {
        guard api.reachable else { return }

        M.isConnectionsPageActive = true

        // WebSocket with raw-Data delivery + payload fingerprinting + incremental
        // diff. The old HTTP poll at 1.5 s decoded a full snapshot of ~14 String
        // fields × N connections every tick, regardless of whether anything
        // changed. The WS fires only on state-change; when it does fire with
        // identical bytes we skip the decode entirely.
        //
        // A 5 s fallback poll covers WS edge cases (mihomo not pushing after a
        // reconnect, missed messages) — cheap, and guarantees the table never
        // goes stale.
        startWebSocket()
        fallbackTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.fallbackPoll() }
        }
    }

    func stop() {
        wsHandle?.cancel()
        wsHandle = nil
        fallbackTimer?.invalidate()
        fallbackTimer = nil

        M.isConnectionsPageActive = false

        // Completely reclaim memory arrays when not on this page
        conns.removeAll(keepingCapacity: false)
        closedConnections.removeAll(keepingCapacity: false)
        prevConnById.removeAll(keepingCapacity: false)
        lastPayloadFingerprint = 0
    }

    private func startWebSocket() {
        wsHandle?.cancel()
        wsHandle = api.streamRaw("/connections") { [weak self] data in
            Task { @MainActor [weak self] in
                self?.onConnectionsData(data)
            }
        }
    }

    private func fallbackPoll() async {
        guard api.reachable else { return }
        do {
            let s = try await api.fetchConnectionsSnapshot()
            // Bypass the fingerprint path — HTTP GET always returns fresh data,
            // so decode and process directly.
            onConnections(s)
        } catch {
            // Network transient — WS will pick up
        }
    }

    private func onConnectionsData(_ data: Data) {
        // Payload fingerprint: if the bytes are identical to the last message,
        // skip the decode entirely — no JSONDecoder, no Conn allocation, no diff.
        let fingerprint = Self.fingerprint(of: data)
        if fingerprint == lastPayloadFingerprint && !conns.isEmpty { return }
        lastPayloadFingerprint = fingerprint

        // Decode inside an autoreleasepool so JSONDecoder's temporaries drain
        // immediately instead of stacking on the main run loop's pool.
        autoreleasepool {
            guard let s = try? JSONDecoder().decode(ConnectionsSnapshot.self, from: data) else { return }
            onConnections(s)
        }
    }

    private func onConnections(_ s: ConnectionsSnapshot) {
        // Delegate the heavy shared work (byte diff, history, gateway, dashboard,
        // memory guard) to the single canonical path. This eliminates the
        // duplicate processing that used to run here AND in recordHistoryOnly.
        M.recordHistoryOnly(from: s)

        let items = s.connections ?? []

        autoreleasepool {
            // Build a lookup of the previous frame so we can reuse the
            // expensive string transforms (chain join, rule concat) that
            // don't change for a given connection.
            if prevConnById.isEmpty {
                for c in M.cachedConns { prevConnById[c.id] = c }
            }

            var next: [Conn] = []
            next.reserveCapacity(items.count)
            var activeIDs = Set<String>(minimumCapacity: items.count)

            for c in items {
                activeIDs.insert(c.id)
                let prev = M.prevConnBytes[c.id]
                let upRate = prev.map { max(0, c.upload - $0.up) } ?? 0
                let downRate = prev.map { max(0, c.download - $0.down) } ?? 0

                // Reuse string transforms from the previous frame when the
                // connection is not new — chains/rule rarely change for a
                // live connection, so this saves 3 string allocations per row.
                let prevConn = prevConnById[c.id]
                let conn = Conn(
                    id: c.id,
                    host: c.metadata.host?.isEmpty == false ? c.metadata.host! : (c.metadata.destinationIP ?? "?"),
                    dstIP: c.metadata.destinationIP ?? "?",
                    srcIP: c.metadata.sourceIP ?? "?",
                    port: c.metadata.destinationPort ?? "",
                    network: c.metadata.network == "tcp" ? "TCP" : c.metadata.network.uppercased(),
                    process: c.metadata.process ?? "—",
                    processPath: c.metadata.processPath ?? "—",
                    chain: prevConn?.chain ?? c.chains.reversed().joined(separator: " → "),
                    group: c.chains.last ?? "?",
                    node: c.chains.first ?? "?",
                    rule: prevConn?.rule ?? (c.rulePayload.isEmpty ? c.rule : "\(c.rule),\(c.rulePayload)"),
                    ruleType: c.rule,
                    up: c.upload, down: c.download,
                    upRate: upRate, downRate: downRate,
                    start: c.start
                )
                next.append(conn)
            }

            // Detect closed connections
            var newClosed = [Conn]()
            for conn in M.cachedConns {
                if !activeIDs.contains(conn.id) {
                    var closedConn = conn
                    closedConn.upRate = 0
                    closedConn.downRate = 0
                    newClosed.append(closedConn)
                }
            }

            if !newClosed.isEmpty {
                M.cachedClosedConnections.insert(contentsOf: newClosed, at: 0)
            }

            // Sorted by rate, then clamped
            M.cachedConns = next.sorted { $0.downRate + $0.upRate > $1.downRate + $1.upRate }
            M.clampConnectionCaches()

            // Update prevConnById for the next frame
            prevConnById.removeAll(keepingCapacity: true)
            for c in M.cachedConns { prevConnById[c.id] = c }

            conns = M.cachedConns
            closedConnections = M.cachedClosedConnections
        }

        // App memory has its own sampler on AppModel; writing it here as well
        // would bypass the change short-circuit and republish `live` on every
        // 1.5 s connections tick.
    }

    /// Cheap non-cryptographic fingerprint — byte count XOR'd with a rolling
    /// hash of the first/last 256 bytes. Sufficient to detect identical
    /// payloads without hashing the entire (potentially 200KB+) JSON.
    private static func fingerprint(of data: Data) -> UInt64 {
        var hash: UInt64 = UInt64(data.count)
        let prefix = min(256, data.count)
        for i in 0..<prefix {
            hash = hash &* 31 &+ UInt64(data[data.startIndex + i])
        }
        if data.count > 256 {
            let suffixStart = data.count - min(256, data.count - 256)
            for i in suffixStart..<data.count {
                hash = hash &* 31 &+ UInt64(data[data.startIndex + i])
            }
        }
        return hash
    }
}
