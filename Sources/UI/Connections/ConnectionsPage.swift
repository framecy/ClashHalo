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

    // Computed filtered & sorted rows (cached per body evaluation)
    private var filteredRows: [Conn] {
        let source = selectedTab == 0 ? VM.conns : VM.closedConnections
        return source.filter { matches($0) }.sorted(using: sortOrder)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: DS.Spacing.m) {
                Picker("", selection: $selectedTab) {
                    Text("连接中").tag(0)
                    Text("已关闭").tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .dsToolbarControl()
                .frame(width: 160)

                HStack(spacing: DS.Spacing.s) {
                    Image(systemName: "magnifyingglass").foregroundColor(.secondary).font(.dsBody)
                    TextField("搜索域名 / 进程 / 规则", text: $q)
                        .textFieldStyle(.plain)
                        .font(.dsBody)
                }
                .dsSearchFieldChrome(maxWidth: 280)

                Spacer(minLength: 0)

                Text("\(filteredRows.count) 匹配").font(.dsBody).foregroundColor(.secondary)

                Button(role: .destructive) { showConfirmDisconnect = true } label: {
                    Label("全部断开", systemImage: "xmark.circle")
                }
                .buttonStyle(.bordered)
                .dsToolbarControl()
            }
            .padding(.horizontal, DS.Layout.pageContentInset)
            .padding(.vertical, DS.Spacing.m)
            .background(DS.Palette.chromeBg)
            Divider()

            if filteredRows.isEmpty {
                ContentUnavailable(q.isEmpty ? (selectedTab == 0 ? "暂无活跃连接" : "暂无已关闭连接") : "无匹配结果", "point.3.connected.trianglepath.dotted")
                    .frame(maxHeight: .infinity)
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
            if !M.engine.configFilePath.isEmpty {
                ruleModel.setTargetPath(M.engine.configFilePath)
                ruleModel.load()
            }
        }
        .onDisappear {
            VM.stop()
        }
        .onChange(of: M.engine.configFilePath) { _, path in
            if !path.isEmpty {
                ruleModel.setTargetPath(path)
                ruleModel.load()
            }
        }
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
}

// MARK: - Conn Detail Popup
struct ConnDetailCard: View {
    let conn: Conn
    let onClose: () -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("连接详情", systemImage: "info.circle.fill")
                    .font(.headline)
                    .foregroundColor(.primary)
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark.circle.fill").foregroundColor(.secondary) }
                    .buttonStyle(.plain)
            }
            
            Divider()
            
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
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
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
        .shadow(color: DS.Palette.cardShadow, radius: 16, x: 0, y: 8)
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                .stroke(DS.Palette.border, lineWidth: 1)
        )
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
        M.prevConnBytes = bytes

        // Compute dashboard stats from raw items before conversion
        M.dash = AppModel.computeDashRaw(items)

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
