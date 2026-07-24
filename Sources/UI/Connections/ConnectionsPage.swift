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

    // Sort & Selection
    @State private var sortOrder = [KeyPathComparator(\Conn.downRate, order: .reverse)]
    @State private var selection: Conn.ID? = nil

    // Rule Editor
    @StateObject private var ruleModel = RuleEditorModel(targetFilePath: "")
    @State private var activeRuleEdit: RuleEditContext? = nil

    // Cached filter/sort — recompute only when inputs change (not every body pass).
    @State private var filteredRows: [Conn] = []
    @State private var filterFingerprint: String = ""

    /// 分流类别筛选 — 原型筛选 chips：全部 / 代理 / 直连 / 拒绝。
    @State private var category: String = "all"

    private func recomputeFilteredRowsIfNeeded() {
        let source = selectedTab == 0 ? VM.conns : VM.closedConnections
        // Fingerprint source identity + query + tab + sort keys. Conn is Equatable;
        // using count + first/last id + rate sum is a cheap churn detector.
        let rateSum = source.reduce(into: Int64(0)) { $0 += $1.downRate &+ $1.upRate }
        let head = source.first?.id ?? "-"
        let tail = source.last?.id ?? "-"
        let sortKey = sortOrder.map { "\($0.keyPath):\($0.order == .forward ? "f" : "r")" }.joined(separator: ",")
        let fp = "\(selectedTab)|\(q)|\(category)|\(source.count)|\(head)|\(tail)|\(rateSum)|\(sortKey)"
        guard fp != filterFingerprint else { return }
        filterFingerprint = fp
        filteredRows = source.filter { matches($0) }.sorted(using: sortOrder)
        categoryCounts = source.reduce(into: [String: Int]()) { acc, c in acc[c.category, default: 0] += 1 }
        categoryCounts["all"] = source.count
    }

    @State private var categoryCounts: [String: Int] = [:]

    var body: some View {
        VStack(spacing: 0) {
            PageHead(title: "连接监控") {
                DSSegmentedControl(selection: $selectedTab, choices: [
                    DSChoice("连接中", 0),
                    DSChoice("已关闭", 1)
                ])
                .frame(width: 150)

                Button(role: .destructive) { showConfirmDisconnect = true } label: {
                    Label("全部断开", systemImage: "xmark.circle")
                }
                .dsButton(.destructive)
            }

            // 搜索 + 类别筛选 chips（原型 03-connections 第二行）
            HStack(alignment: .center, spacing: DS.Spacing.s) {
                HStack(spacing: DS.Spacing.s) {
                    Image(systemName: "magnifyingglass").foregroundColor(.secondary).font(.dsBody)
                    TextField("搜索 域名 / IP / 进程 / 规则…", text: $q)
                        .textFieldStyle(.plain)
                        .font(.dsBody)
                }
                .dsSearchFieldChrome(maxWidth: 260)

                ForEach(Self.categories, id: \.0) { key, label in
                    DSFilterChip(title: label, count: categoryCounts[key] ?? 0,
                                 selected: category == key) {
                        category = key
                    }
                }

                Spacer(minLength: DS.Spacing.s)

                Text("\(filteredRows.count) 条匹配")
                    .font(.dsCaption)
                    .monospacedDigit()
                    .foregroundColor(DS.Palette.textFaint)
            }
            .padding(.horizontal, DS.Layout.pageContentInset)
            .padding(.bottom, DS.Spacing.m)

            if filteredRows.isEmpty {
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
                            Text(c.host).font(.dsBodySemibold).lineLimit(1).truncationMode(.middle)
                            Text("\(c.dstIP):\(c.port)")
                                .font(.dsMonoTiny).foregroundColor(DS.Palette.textFaint).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }.width(min: 180, ideal: 240)
                    TableColumn("进程", value: \.process) { c in
                        Text(c.process).font(.dsBody).foregroundColor(.secondary).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.width(min: 80, ideal: 120)
                    TableColumn("类型", value: \.network) { c in
                        DSProtoTag(type: c.network)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.width(52)
                    TableColumn("规则", value: \.rule) { c in
                        Text(c.rule).font(.dsMonoSm).foregroundColor(.secondary).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }.width(min: 100, ideal: 150)
                    TableColumn("代理链", value: \.chain) { c in
                        HStack(spacing: 5) {
                            Text(c.group)
                                .font(.dsBodySemibold)
                                .foregroundColor(chainColor(c))
                                .lineLimit(1)
                            Text(c.node).font(.dsMonoTiny).foregroundColor(DS.Palette.textFaint).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }.width(min: 120, ideal: 180)
                    TableColumn("↑ 速率", value: \.upRate) { c in
                        Text(c.category == "reject" ? "—" : fmtRate(Double(c.upRate)))
                            .font(.dsMonoSm).monospacedDigit()
                            .foregroundColor(c.category == "reject" ? DS.Palette.textFaint : .secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }.width(78)
                    TableColumn("↓ 速率", value: \.downRate) { c in
                        Text(c.category == "reject" ? "阻断" : fmtRate(Double(c.downRate)))
                            .font(.dsMonoSm).monospacedDigit()
                            .foregroundColor(c.category == "reject" ? DS.Palette.textFaint : .primary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }.width(78)
                    TableColumn("总量", value: \.down) { c in
                        Text(fmtBytes(Double(c.down + c.up)))
                            .font(.dsMonoSm).monospacedDigit().foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }.width(72)
                    TableColumn("") { c in
                        if selectedTab == 0 {
                            Button { M.closeConnection(id: c.id) } label: { Image(systemName: "xmark.circle") }
                                .buttonStyle(.borderless).foregroundColor(.secondary).help("断开此连接")
                        }
                    }.width(30)
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
        .onChange(of: category) { _, _ in recomputeFilteredRowsIfNeeded() }
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

                if ruleModel.save() {
                    M.reloadActiveConfig()
                    M.closeConnection(id: ctx.conn.id)
                }
            }
        }
    }

    /// 类别筛选项 — 键与 `Conn.category` 同源。
    private static let categories: [(String, String)] = [
        ("all", "全部"), ("proxy", "代理"), ("direct", "直连"), ("reject", "拒绝")
    ]

    private func chainColor(_ c: Conn) -> Color {
        switch c.category {
        case "proxy": return DS.Palette.accent
        case "reject": return DS.Palette.error
        default: return .secondary
        }
    }

    private func matches(_ c: Conn) -> Bool {
        guard category == "all" || c.category == category else { return false }
        return q.isEmpty
            || c.host.localizedCaseInsensitiveContains(q)
            || c.dstIP.localizedCaseInsensitiveContains(q)
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
        .padding(DS.Spacing.l)
        .frame(width: 340)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                .strokeBorder(DS.Palette.borderStrong, lineWidth: 0.5)
        )
        // 浮层需要真实投影与内容区拉开层次（卡片本身走 0.5px 边框，不用投影）。
        .shadow(color: .black.opacity(0.28), radius: 24, x: 0, y: 10)
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

    private var pollTimer: Timer?
    private let api = MihomoClient.shared
    private let M = AppModel.shared

    func start() {
        guard api.reachable else { return }

        M.isConnectionsPageActive = true

        // HTTP polling instead of WebSocket — avoids kernel pushing full-payload
        // JSON every 1s which causes severe memory churn under high connection count.
        // Poll at 1.5s gives near-realtime UX while halving allocation frequency.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.poll()
            }
        }
        // Immediate first fetch
        Task { await poll() }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil

        M.isConnectionsPageActive = false

        // Completely reclaim memory arrays when not on this page
        conns.removeAll(keepingCapacity: false)
        closedConnections.removeAll(keepingCapacity: false)
    }

    private func poll() async {
        guard api.reachable else { return }
        do {
            let s = try await api.fetchConnectionsSnapshot()
            onConnections(s)
        } catch {
            // Network transient — skip this tick
        }
    }

    private func onConnections(_ s: ConnectionsSnapshot) {
        M.uploadTotal = s.uploadTotal
        M.downloadTotal = s.downloadTotal

        if let m = s.memory, m > 0 {
            M.memory = m
            // Core Memory Guard
            if m > 512 * 1024 * 1024 && Date().timeIntervalSince(M.lastCacheFlush) > 1800 {
                M.lastCacheFlush = Date()
                M.clearAllCache()
                M.logKernel("核心内存占用过高 (\(m / 1_000_000)MB)，已自动清空 DNS 与 Fake‑IP 缓存")
            }
        }

        let items = s.connections ?? []
        var next: [Conn] = []
        var bytes: [String: (up: Int64, down: Int64)] = [:]
        var activeIDs = Set<String>()
        let hour = Calendar.current.component(.hour, from: Date())

        for c in items {
            activeIDs.insert(c.id)
            if !M.activeConnsSet.contains(c.id) { M.totalConnsCount += 1 }
            let prev = M.prevConnBytes[c.id]
            let upRate = prev.map { max(0, c.upload - $0.up) } ?? 0
            let downRate = prev.map { max(0, c.download - $0.down) } ?? 0
            bytes[c.id] = (c.upload, c.download)

            let cat = (c.chains.first == "DIRECT" || c.chains.contains("DIRECT")) ? "direct"
                    : (c.chains.first == "REJECT" || c.chains.contains("REJECT")) ? "reject" : "proxy"
            M.history.record(category: cat, down: Int64(downRate), up: Int64(upRate), hour: hour)

            let conn = Conn(
                id: c.id,
                host: c.metadata.host?.isEmpty == false ? c.metadata.host! : (c.metadata.destinationIP ?? "?"),
                dstIP: c.metadata.destinationIP ?? "?",
                srcIP: c.metadata.sourceIP ?? "?",
                port: c.metadata.destinationPort ?? "",
                network: c.metadata.network.uppercased(),
                process: c.metadata.process ?? "—",
                processPath: c.metadata.processPath ?? "—",
                chain: c.chains.reversed().joined(separator: " → "),
                group: c.chains.last ?? "?",
                node: c.chains.first ?? "?",
                rule: c.rulePayload.isEmpty ? c.rule : "\(c.rule),\(c.rulePayload)",
                ruleType: c.rule,
                up: c.upload, down: c.download,
                upRate: upRate, downRate: downRate,
                start: c.start
            )
            next.append(conn)
        }
        // Gateway aggregation must run before prevConnBytes is overwritten.
        if M.gatewayModeOn {
            M.updateGatewayDevices(from: items)
        }

        M.prevConnBytes = bytes

        // Compute dashboard stats from raw items before conversion
        if M.route == "dashboard" || M.route == "connections" {
            let next = AppModel.computeDashRaw(items)
            if next != M.dash { M.dash = next }
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
            if M.cachedClosedConnections.count > 200 {
                M.cachedClosedConnections.removeLast(M.cachedClosedConnections.count - 200)
            }
        }
        M.activeConnsSet = activeIDs

        let sorted = next.sorted { $0.downRate + $0.upRate > $1.downRate + $1.upRate }
        M.cachedConns = sorted

        conns = M.cachedConns
        closedConnections = M.cachedClosedConnections
        M.activeConnectionsCount = activeIDs.count

        M.closedConns = max(0, M.totalConnsCount - activeIDs.count)
        M.history.flushIfNeeded()
        M.lastDownTotal = s.downloadTotal

        M.appMemoryMB = Double(AppModel.residentMemoryBytes()) / 1_000_000
    }
}
