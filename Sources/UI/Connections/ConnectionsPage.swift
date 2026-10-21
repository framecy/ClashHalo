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
        /// 打开弹窗那一刻的真实目标名快照（策略组 + 节点 + 内置 + config.yaml 里的组）。
        /// 用快照而不是每次求值：`AppModel.ruleTargetNames` 会读一次 config.yaml，
        /// 不能放在 body / sheet 闭包的渲染路径上反复执行。
        let knownTargets: Set<String>
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
            // P2-3：文档列了 5 页手搓顶栏，这里是第 6 处（同一契约的复制品）。
            // 不一起收进来，“顶栏只有一处实现”就仍然不成立。
            PageToolbar(leading: {
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
            }, actions: {
                Text("\(filteredRows.count) 匹配").font(.dsBody).foregroundColor(.secondary)

                Button(role: .destructive) { showConfirmDisconnect = true } label: {
                    Label("全部断开", systemImage: "xmark.circle")
                }
                .dsButton(.destructive)
            })

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
                connTable

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
            RuleFormView(existingNode: ctx.node,
                         proxyGroups: M.groups.map { $0.name },
                         knownTargets: ctx.knownTargets,
                         contextConn: ctx.conn) { newNode in
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

    /// 表格「来源」列的判定。本机地址集合用 `M.localIPs`（连接快照每拍刷新一次），
    /// 不在这里逐行调 `getifaddrs`——表格一次渲染有 N 行，系统调用会被放大成开销。
    /// `srcIP == "?"` 是 `Conn` 的「字段缺失」占位，必须当空串交给判定器。
    private func origin(for c: Conn) -> ConnOrigin {
        ConnOriginClassifier.classify(
            inboundName: c.inboundName,
            inboundPort: c.inboundPort,
            sourceIP: c.srcIP == "?" ? "" : c.srcIP,
            localIPs: M.localIPs
        )
    }

    /// 连接表单独成一个属性：`Table` 的列构造器是巨型表达式，嵌在页面 body 里
    /// 再加一列就越过类型检查预算（实测加到 8 列即超时）。拆开后各自推导。
    ///
    /// 「来源」列是常驻列，不做显隐切换：条件列（`if`）在 `TableColumnBuilder` 里
    /// 需要 macOS 14.4+，本工程部署目标 14.0；用 `TableColumnCustomization` 隐藏
    /// 会多出一条「表头右键」的控制路径，与自绘开关不同步。列宽压到 88pt 即可。
    private var connTable: some View {
        Table(filteredRows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("目标", value: \.host) { c in
                targetCell(c)
            }.width(min: 180, ideal: 240)
            TableColumn("进程", value: \.process) { c in
                processCell(c)
            }.width(min: 80, ideal: 120)
            TableColumn("来源") { c in
                sourceCell(c)
            }.width(min: 88, ideal: 118)
            TableColumn("规则", value: \.rule) { c in
                ruleCell(c)
            }.width(min: 100, ideal: 150)
            TableColumn("链路", value: \.chain) { c in
                chainCell(c)
            }.width(min: 120, ideal: 180)
            TableColumn("↓", value: \.downRate) { c in
                downCell(c)
            }.width(70)
            TableColumn("↑", value: \.upRate) { c in
                upCell(c)
            }.width(70)
            TableColumn("") { c in
                actionCell(c)
            }.width(36)
        }
        // Lock table content inset to the same token as the toolbar strip.
        .contentMargins(.horizontal, DS.Layout.pageContentInset, for: .scrollContent)
        .contextMenu(forSelectionType: Conn.ID.self) { ids in
            if let id = ids.first, let c = filteredRows.first(where: { $0.id == id }) {
                Button("添加/修改分流规则...") {
                    prepareRuleEdit(for: c)
                }

                // 一键「独立制裁」：写规则 → 校验 → reload → 断开。
                // 决策（写哪种规则、能不能写）在 `QuickRule`（纯逻辑、有回归套件），
                // 这里只把结果交给既有事务，不另起保存路径。
                Divider()
                quickRuleSection(for: c)

                if selectedTab == 0 {
                    Divider()
                    Button("断开连接", role: .destructive) {
                        M.closeConnection(id: c.id)
                    }
                }
            }
        }
    }

    // MARK: - 表格单元格
    //
    // 每个单元格都抽成独立 `@ViewBuilder`：`Table` 的列构造器是一个巨型表达式，
    // 单元格写在里面时再加一列就会「unable to type-check in reasonable time」。
    // 拆出来之后每个单元格各自推导，列定义只剩 `TableColumn(...) { cell(c) }`。

    @ViewBuilder
    private func targetCell(_ c: Conn) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(c.host).font(.dsBodyMedium).lineLimit(1)
            Text("\(c.dstIP):\(c.port)")
                .font(.dsMono)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func processCell(_ c: Conn) -> some View {
        Text(c.process)
            .font(.dsBody)
            .foregroundColor(.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func ruleCell(_ c: Conn) -> some View {
        Text(c.rule)
            .font(.dsMono)
            .foregroundColor(.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func chainCell(_ c: Conn) -> some View {
        HStack(spacing: 4) {
            Text(c.chain)
                .font(.dsBodySemibold)
                .foregroundColor(c.category == "proxy" ? DS.Palette.accent : .secondary)
                .lineLimit(1)
            Text(c.node)
                .font(.dsMono)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func downCell(_ c: Conn) -> some View {
        Text(fmtRate(Double(c.downRate)))
            .font(.dsMono)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func upCell(_ c: Conn) -> some View {
        Text(fmtRate(Double(c.upRate)))
            .font(.dsMono)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func actionCell(_ c: Conn) -> some View {
        if selectedTab == 0 {
            Button { M.closeConnection(id: c.id) } label: { Image(systemName: "xmark.circle") }
                .buttonStyle(.borderless)
                .foregroundColor(.secondary)
                .help("断开此连接")
        }
    }

    /// 「来源」列的单元格。单独抽成 `@ViewBuilder` 方法，是为了让类型检查在
    /// 这里收口——直接写进 `Table` 的列构造器会把那一大团表达式的推导顶到超时。
    @ViewBuilder
    private func sourceCell(_ c: Conn) -> some View {
        let o = origin(for: c)
        Text(o.shortLabel)
            .font(.dsBody)
            .foregroundColor(.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(sourceHelp(c, o))
    }

    /// 「来源」列的完整证据（悬停提示）：标题 + 入站副标题。列里只放短标签，
    /// 完整判定过程放进 help，避免为了一列多占宽度。
    private func sourceHelp(_ c: Conn, _ o: ConnOrigin) -> String {
        let src = c.srcIP == "?" ? "" : c.srcIP
        return "\(o.title(process: c.process)) · \(o.subtitle(sourceIP: src))"
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

        activeRuleEdit = RuleEditContext(node: finalNode, conn: c,
                                         knownTargets: M.ruleTargetNames)
    }

    // MARK: - 一键「独立制裁」
    //
    // 右键直接按这条连接的目标 / 进程写一条规则，写完立刻校验 + reload，
    // 失败整体回滚（复用 `applyRuleEditorSave` 的备份事务），成功后断开相关连接。
    // 决策全部在 `QuickRule`（纯逻辑 + 回归套件），这里只做接线。

    private var canWriteQuickRule: Bool {
        !M.engine.configFilePath.isEmpty && !M.engine.isBusy
    }

    private func quickContext(_ c: Conn) -> QuickRuleContext {
        QuickRuleContext(host: c.host,
                         dstIP: c.dstIP,
                         remoteDestination: c.remoteDestination,
                         process: c.process,
                         group: c.group,
                         availableGroups: M.groups.map { $0.name })
    }

    /// 同主机名的活跃连接数——「拉黑」会连坐这些连接，必须先说清数量。
    private func sameHostCount(_ c: Conn) -> Int {
        let key = c.host.isEmpty ? c.dstIP : c.host
        return VM.conns.reduce(into: 0) { n, other in
            if (other.host.isEmpty ? other.dstIP : other.host) == key { n += 1 }
        }
    }

    @ViewBuilder
    private func quickRuleSection(for c: Conn) -> some View {
        let ctx = quickContext(c)
        let direct = QuickRule.plan(.direct, context: ctx, existing: ruleModel.nodes)
        let reject = QuickRule.plan(.reject, context: ctx, existing: ruleModel.nodes)
        let process = QuickRule.plan(.processGroup, context: ctx, existing: ruleModel.nodes)
        let host = c.host.isEmpty ? c.dstIP : c.host

        Button("让 \(host) 直连") { applyQuickRule(.direct, for: c) }
            .disabled(!canWriteQuickRule || direct == nil)

        Button("拉黑 \(host)（影响 \(sameHostCount(c)) 条连接）") { applyQuickRule(.reject, for: c) }
            .disabled(!canWriteQuickRule || reject == nil)

        Button(process?.proxyGroup.map { "这个 App 走「\($0)」" } ?? "这个 App 走当前策略组") {
            applyQuickRule(.processGroup, for: c)
        }
        .disabled(!canWriteQuickRule || process == nil)
    }

    private func applyQuickRule(_ kind: QuickRuleKind, for c: Conn) {
        let path = M.engine.configFilePath
        guard !path.isEmpty else {
            M.showToast("配置尚未加载，无法写入规则", kind: .warn)
            return
        }
        // 以磁盘上的最新内容为基线：页面停留期间配置可能被网关覆盖、profile 切换
        // 或规则页改写过。
        guard let current = try? String(contentsOfFile: path, encoding: .utf8) else {
            M.showToast("读取配置失败，未写入任何规则", kind: .error)
            return
        }
        let existing = YamlRuleASTEngine.extractRules(from: current)
        guard let plan = QuickRule.plan(kind, context: quickContext(c), existing: existing) else {
            M.showToast("这条连接缺少可写规则的目标信息", kind: .warn)
            return
        }
        let host = c.host.isEmpty ? c.dstIP : c.host

        guard !plan.isNoop else {
            closeAfterQuickRule(kind, conn: c, host: host)
            M.showToast("规则已存在，已按现有规则断开", kind: .ok)
            return
        }

        // 手术式写入，而不是 `RuleEditorModel.save()` 的「按节点重建整个规则块」：
        // 后者会丢掉 rules 块内所有注释与空行（用真实配置实测一次空往返即少 50 行，
        // 其中 43 行是块内注释）。一键加一条规则不该顺带删掉用户手写的证据注释。
        // 事务本身仍复用 `applyRuleEditorSave`（备份 → reload → 失败回滚磁盘）。
        M.applyRuleEditorSave(save: {
            var text = current
            for node in existing where plan.replaceIDs.contains(node.id) {
                text = YamlRuleASTEngine.removeRuleLines(type: node.type, match: node.match, from: text)
            }
            let newNode = RuleNode(type: plan.type, match: plan.match, action: plan.action,
                                   sort: 0, proxyGroup: plan.proxyGroup)
            guard let next = YamlRuleASTEngine.insertRuleLine(
                YamlRuleASTEngine.serialize(node: newNode), into: text) else { return false }
            do {
                try next.write(toFile: path, atomically: true, encoding: .utf8)
            } catch {
                return false
            }
            // 与 RuleEditorModel.save 一致：config.yaml 里有 tailnet auth-key 明文。
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            return true
        }) { ok in
            // 无论成败都让页面里的规则快照回到磁盘真实状态。
            ruleModel.load()
            if ok {
                M.logKernel("[连接页] 写入规则 \(plan.type.rawValue),\(plan.match),"
                    + "\(plan.proxyGroup ?? plan.action.rawValue)"
                    + (plan.replaceIDs.isEmpty ? "" : "（替换同匹配旧规则 \(plan.replaceIDs.count) 条）"))
                closeAfterQuickRule(kind, conn: c, host: host)
            }
        }
    }

    /// 拉黑会连坐同域名的所有会话，一并断开；直连/换组只断当前这一条。
    private func closeAfterQuickRule(_ kind: QuickRuleKind, conn: Conn, host: String) {
        if kind == .reject {
            M.closeConnections(host: host)
        } else {
            M.closeConnection(id: conn.id)
        }
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

            // 四段式「决策链」：来源 → 解析 → 规则 → 出口。
            // 此前是 12 行扁平 Grid（ID / 域名 / IP / 源 IP / 网络 / 进程 / 规则 /
            // 策略 / 节点 / 上下行 / 时间），用户得自己在脑子里把因果拼起来。
            // 现在每一段都是「证据 → 结论」，原始字段收进底部灰字备查。
            section("来源", primary: origin.title(process: conn.process),
                    secondary: origin.subtitle(sourceIP: conn.srcIP == "?" ? "" : conn.srcIP))
            section("解析", primary: dnsText, secondary: sniffText)
            section("规则", primary: conn.rule.isEmpty ? "未命中规则" : conn.rule, mono: true)
            section("出口", primary: exitText, secondary: exitNote, color: exitColor)

            Divider()

            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                metaRow("目标", endpointText)
                if let path = processPathText { metaRow("进程", path) }
                metaRow("网络", conn.network)
                metaRow("时间", formatStartTime(conn.start))
                metaRow("流量", "↓ \(fmtBytes(Double(conn.down))) · ↑ \(fmtBytes(Double(conn.up)))")
                metaRow("ID", conn.id)
            }
            .font(.dsCaption)
        }
        .padding(DS.Spacing.xl)
        .frame(width: 380)
        .background(DS.Palette.overlayBg)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                .stroke(DS.Palette.border, lineWidth: 1)
        )
        .shadow(color: DS.Palette.cardShadowContact, radius: 2, x: 0, y: 1)
        .shadow(color: DS.Palette.cardShadow, radius: 20, x: 0, y: 8)
    }

    // MARK: - 四段式辅助

    /// 来源判定。本机地址集合每次求值一次 `getifaddrs`（几十微秒），且
    /// `updateGatewayDevices` 每拍也在做同样的事；卡片只在选中某行时存在。
    /// `srcIP == "?"` 是 `Conn` 的「字段缺失」占位，必须当空串交给判定器，
    /// 否则会被当成一个叫 `?` 的对端地址判成「外部」。
    private var origin: ConnOrigin {
        ConnOriginClassifier.classify(
            inboundName: conn.inboundName,
            inboundPort: conn.inboundPort,
            sourceIP: conn.srcIP == "?" ? "" : conn.srcIP,
            localIPs: Set(NetScanner.interfaces().flatMap { $0.ipv4 })
        )
    }

    private var dnsText: String {
        switch conn.dnsMode {
        case "fake-ip":    return "Fake-IP · 域名由内核虚拟解析"
        case "normal":     return "普通 DNS · 真实解析"
        case "redir-host": return "Redir-Host · 真实解析"
        case "":           return "内核未提供解析模式"
        default:           return conn.dnsMode
        }
    }

    private var sniffText: String {
        let s = conn.sniffHost.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, s != conn.host else { return "" }
        return "嗅探得到真实域名 \(s)"
    }

    private var exitText: String {
        switch conn.category {
        case "direct": return "DIRECT · 直连"
        case "reject": return "REJECT · 已拒绝"
        default:
            let group = conn.group == "?" ? "未知策略" : conn.group
            return "\(group) → \(conn.node)"
        }
    }

    /// 订阅来源只做展示，不作主信息：`providerChains` 在本地节点上常为空串，
    /// 缺失时留白比猜测「来自某订阅」诚实。
    private var exitNote: String {
        conn.providerChain.isEmpty ? "" : "节点来自订阅 \(conn.providerChain)"
    }

    private var exitColor: Color {
        switch conn.category {
        case "direct": return .secondary
        case "reject": return DS.Palette.error
        default:       return DS.Palette.accent
        }
    }

    /// 域名连接在 fake-ip 下 `destinationIP` 常为空（实测同一刻 72 条连接里 59 条
    /// 为空、且这 59 条的 `remoteDestination` 都有值），此时用真实远端地址兜底。
    /// **端口必须一起带上**：`destinationPort` 这 72 条全都有值，而旧卡片里端口只
    /// 在「目标 IP」那一行出现，兜底路径丢了它等于交出一张查不出端口的详情卡。
    private var endpointText: String {
        let target: String
        if conn.dstIP == "?", !conn.remoteDestination.isEmpty {
            target = conn.remoteDestination
        } else {
            target = conn.dstIP
        }
        let endpoint = conn.port.isEmpty ? target : "\(target):\(conn.port)"
        return "\(conn.host) · \(endpoint)"
    }

    private var processPathText: String? {
        let p = conn.processPath.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty, p != "—" else { return nil }
        return p
    }

    private func section(_ title: String, primary: String, secondary: String = "",
                         color: Color = .primary, mono: Bool = false) -> some View {
        HStack(alignment: .top, spacing: DS.Spacing.s) {
            Text(title)
                .font(.dsCaption)
                .foregroundColor(.secondary)
                .frame(width: 32, alignment: .leading)
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Text(primary)
                    .font(mono ? .dsMono : .dsBodyMedium)
                    .foregroundColor(color)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .truncationMode(.middle)
                if !secondary.isEmpty {
                    Text(secondary)
                        .font(.dsCaption)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func metaRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s) {
            Text(label)
                .foregroundColor(.secondary)
                .frame(width: 32, alignment: .leading)
            Text(value)
                .font(.dsMono)
                .foregroundColor(.secondary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
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
                    start: c.start,
                    // 决策链证据：直接取原文，不做逐行字符串变换（热路径每拍要跑
                    // 几百次）。归一化留给详情卡片按需进行一次。
                    inboundName: c.metadata.inboundName ?? "",
                    inboundPort: c.metadata.inboundPort ?? "",
                    dnsMode: c.metadata.dnsMode ?? "",
                    sniffHost: c.metadata.sniffHost ?? "",
                    remoteDestination: c.metadata.remoteDestination ?? "",
                    // providerChains 与 chains 同序：第 0 位才是叶节点所属订阅。
                    // 早先用 first(where:) 会跳过空位，把外层策略组的 provider 当成
                    // 叶节点的来源——位置语义固定，不能顺手「找到第一个非空」。
                    providerChain: c.providerChains?.first ?? ""
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
