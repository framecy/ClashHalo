import SwiftUI

struct ConnectionsPage: View {
    @EnvironmentObject var M: AppModel
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
    
    var body: some View {
        VStack(spacing: 0) {
            PageHead(title: "连接", desc: selectedTab == 0 ? "\(M.conns.count) 个活跃连接 · 实时速率" : "\(M.closedConnections.count) 个已关闭连接") {
                Button(role: .destructive) { showConfirmDisconnect = true } label: { Label("全部断开", systemImage: "xmark.circle") }
                    .controlSize(.small)
            }

            HStack {
                Picker("", selection: $selectedTab) {
                    Text("连接中").tag(0)
                    Text("已关闭").tag(1)
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
                
                Image(systemName: "magnifyingglass").foregroundColor(.secondary).padding(.leading, 8)
                TextField("搜索域名 / 进程 / 规则", text: $q).textFieldStyle(.plain)
                Spacer()
                
                let sourceConns = selectedTab == 0 ? M.conns : M.closedConnections
                Text("\(sourceConns.filter { matches($0) }.count) 匹配").font(.dsBody).foregroundColor(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.3))
            Divider()

            let sourceConns = selectedTab == 0 ? M.conns : M.closedConnections
            let rows = sourceConns.filter { matches($0) }.sorted(using: sortOrder)
            
            if rows.isEmpty {
                ContentUnavailable(q.isEmpty ? (selectedTab == 0 ? "暂无活跃连接" : "暂无已关闭连接") : "无匹配结果", "point.3.connected.trianglepath.dotted")
                    .frame(maxHeight: .infinity)
                    .onTapGesture { selection = nil }
            } else {
                Table(rows, selection: $selection, sortOrder: $sortOrder) {
                    TableColumn("目标", value: \.host) { c in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(c.host).font(.dsBodyMedium).lineLimit(1)
                            Text("\(c.dstIP):\(c.port)").font(.dsMono).foregroundColor(.secondary)
                        }
                    }.width(min: 180, ideal: 240)
                    TableColumn("进程", value: \.process) { c in Text(c.process).font(.dsBody).foregroundColor(.secondary).lineLimit(1) }.width(min: 80, ideal: 120)
                    TableColumn("规则", value: \.rule) { c in Text(c.rule).font(.dsMono).foregroundColor(.secondary).lineLimit(1) }.width(min: 100, ideal: 150)
                    TableColumn("链路", value: \.chain) { c in
                        HStack(spacing: 4) {
                            Text(c.chain).font(.dsBodySemibold).foregroundColor(c.category == "proxy" ? M.accent : .secondary).lineLimit(1)
                            Text(c.node).font(.dsMono).foregroundColor(.secondary)
                        }
                    }.width(min: 120, ideal: 180)
                    TableColumn("↓", value: \.downRate) { c in Text(fmtRate(Double(c.downRate))).font(.dsMono) }.width(70)
                    TableColumn("↑", value: \.upRate) { c in Text(fmtRate(Double(c.upRate))).font(.dsMono).foregroundColor(.secondary) }.width(70)
                    TableColumn("") { c in
                        if selectedTab == 0 {
                            Button { M.closeConnection(id: c.id) } label: { Image(systemName: "xmark.circle") }
                                .buttonStyle(.borderless).foregroundColor(.secondary).help("断开此连接")
                        }
                    }.width(36)
                }
                .contextMenu(forSelectionType: Conn.ID.self) { ids in
                    if let id = ids.first, let c = rows.first(where: { $0.id == id }) {
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
            if !M.engine.configFilePath.isEmpty {
                ruleModel.setTargetPath(M.engine.configFilePath)
                ruleModel.load()
            }
        }
        .onChange(of: M.engine.configFilePath) { _, path in
            if !path.isEmpty {
                ruleModel.setTargetPath(path)
                ruleModel.load()
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let id = selection, let c = (M.conns + M.closedConnections).first(where: { $0.id == id }) {
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
        q.isEmpty || "\(c.host)\(c.process)\(c.chain)\(c.rule)".localizedCaseInsensitiveContains(q)
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
        .padding(20)
        .frame(width: 340)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.3), radius: 30, x: 0, y: 15)
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.15), lineWidth: 1)
        )
    }
    
    private func formatStartTime(_ isoString: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: isoString) {
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd HH:mm:ss"
            return df.string(from: date)
        }
        return String(isoString.prefix(19)).replacingOccurrences(of: "T", with: " ")
    }
}
