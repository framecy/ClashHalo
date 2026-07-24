import SwiftUI

// MARK: - 节点管理：本地节点 / 订阅节点 两个 tab，卡片 + sheet 编辑
//
// 卡片列表 + sheet 编辑是这个 App 别处（配置、代理、规则……）统一在用的模式；
// 之前试过左右主从布局，是这个 App 里唯一一处这么做的地方，没有其它页面可以
// 参照复用视觉规范，被打回——按需求改回卡片 + tab。

struct SubscriptionsPage: View {
    @EnvironmentObject var M: AppModel
    @State private var providers: [ProviderEntry] = []
    @State private var localNodes: [LocalProxy] = []
    /// 节点名 -> 读取时捕获的未识别原始行（ws-opts 等）。编辑该节点时原样带回，
    /// 不因为这次编辑冲掉手改过的额外内容。
    @State private var localExtraLines: [String: [String]] = [:]
    @State private var busy: Set<String> = []
    @State private var tab: NodeTab = .all

    @State private var showAddChoice = false

    // 订阅 sheet
    @State private var showSubSheet = false
    @State private var editSubName: String? = nil
    @State private var fName = ""
    @State private var fURL = ""
    @State private var confirmDeleteSub: String? = nil

    // 本地节点 sheet
    @State private var showNodeSheet = false
    @State private var editingNode: LocalProxy? = nil   // nil = 新增 / 分叉
    @State private var forkPrefill: LocalProxy? = nil   // 仅分叉时非 nil，见 NodeFormSheet.prefill 的注释
    @State private var confirmDeleteNode: String? = nil

    // 订阅节点分叉确认
    @State private var forkTarget: (provider: String, node: String)? = nil

    enum NodeTab: Hashable { case all, local, subscription }

    var body: some View {
        ScrollView {
            VStack(spacing: DS.Spacing.m) {
                PageHead(title: "节点管理") {
                    // 订阅节点 tab 下"全部更新"排最前——这是这一屏最高频的动作，
                    // 夹在 tab 切换和添加按钮中间容易被忽略。
                    if tab == .subscription {
                        Button { Task { await updateAll() } } label: {
                            Label("全部更新", systemImage: "arrow.clockwise")
                        }
                        .dsButton()
                        .disabled(providers.isEmpty)
                    }

                    DSSegmentedControl(selection: $tab, choices: [
                        DSChoice("全部", NodeTab.all),
                        DSChoice("本地节点", NodeTab.local),
                        DSChoice("订阅节点", NodeTab.subscription),
                    ])
                    .fixedSize()

                    Button { showAddChoice = true } label: {
                        Label("添加节点", systemImage: "plus")
                    }
                    .dsButton(.prominent)
                    .popover(isPresented: $showAddChoice, arrowEdge: .bottom) {
                        addChoicePopover
                    }
                }
                .padding(.horizontal, -DS.Layout.pageContentInset)

                switch tab {
                case .all: allNodesContent
                case .local: localNodesContent
                case .subscription: subscriptionsContent
                }
            }
            .padding(.horizontal, DS.Layout.pageContentInset)
            .padding(.bottom, 26)
        }
        .task { await reload() }
        .sheet(isPresented: $showSubSheet) { subscriptionSheet }
        .sheet(isPresented: $showNodeSheet) {
            NodeFormSheet(
                existing: editingNode,
                prefill: forkPrefill,
                extraLines: editingNode.flatMap { localExtraLines[$0.name] } ?? [],
                defaultGroup: M.engine.firstSelectGroupName(),
                availableGroups: M.groups.filter { $0.type == "Selector" }.map(\.name),
                onSave: { proxy, extraLines, group in
                    Task { await saveNode(proxy, extraLines: extraLines, addToGroup: group) }
                }
            )
        }
        .confirmationDialog("将「\(forkTarget?.node ?? "")」分叉为本地节点？",
                            isPresented: Binding(get: { forkTarget != nil },
                                                  set: { if !$0 { forkTarget = nil } }),
                            titleVisibility: .visible) {
            Button("分叉并编辑") {
                if let t = forkTarget { beginForkNode(provider: t.provider, node: t.node) }
                forkTarget = nil
            }
            Button("取消", role: .cancel) { forkTarget = nil }
        } message: {
            Text("订阅节点由订阅整体管理，无法单独编辑。分叉会生成一份独立的本地节点副本，"
                 + "可以自由修改；但这份副本此后不再随订阅刷新更新，订阅那边的参数变化不会同步过来。")
        }
        .confirmationDialog("删除订阅「\(confirmDeleteSub ?? "")」？",
                            isPresented: Binding(get: { confirmDeleteSub != nil },
                                                  set: { if !$0 { confirmDeleteSub = nil } }),
                            titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let n = confirmDeleteSub { Task { await deleteSubscription(n) } }
                confirmDeleteSub = nil
            }
        } message: { Text("将从配置中移除该 proxy-provider 及其在策略组中的引用。") }
        .confirmationDialog("删除节点「\(confirmDeleteNode ?? "")」？",
                            isPresented: Binding(get: { confirmDeleteNode != nil },
                                                  set: { if !$0 { confirmDeleteNode = nil } }),
                            titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let n = confirmDeleteNode { Task { await deleteNode(n) } }
                confirmDeleteNode = nil
            }
        } message: { Text("将从配置中移除该节点及其在策略组中的引用。") }
    }

    private var addChoicePopover: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button { showAddChoice = false; beginAddSubscription() } label: {
                Label("添加订阅节点", systemImage: "icloud.and.arrow.down")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, DS.Spacing.m)
            .frame(height: DS.Layout.controlHeight)

            Button { showAddChoice = false; beginAddLocalNode() } label: {
                Label("添加本地节点", systemImage: "plus.circle")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, DS.Spacing.m)
            .frame(height: DS.Layout.controlHeight)
        }
        .padding(.vertical, DS.Spacing.xs)
        .frame(width: 200)
    }

    // MARK: 本地节点 tab

    /// "全部"tab——默认视图，本地+订阅节点合并展示。两边都有内容才分别加
    /// 分区标题；只有一边有内容时不必要地加个标题反而显得空。
    @ViewBuilder
    private var allNodesContent: some View {
        if localNodes.isEmpty && providers.isEmpty {
            ContentUnavailable("暂无节点 · 点右上角「添加节点」", "square.stack.3d.up")
                .frame(minHeight: 320)
        } else {
            if !localNodes.isEmpty {
                if !providers.isEmpty { sectionLabel("本地节点") }
                ForEach(localNodes) { n in localNodeCard(n) }
            }
            if !providers.isEmpty {
                if !localNodes.isEmpty { sectionLabel("订阅节点") }
                ForEach(providers, id: \.name) { p in subscriptionCard(p) }
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.dsSectionLabel)
            .foregroundStyle(DS.Palette.textFaint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, DS.Spacing.xs)
    }

    @ViewBuilder
    private var localNodesContent: some View {
        if localNodes.isEmpty {
            ContentUnavailable("暂无本地节点 · 点右上角「添加节点」", "server.rack")
                .frame(minHeight: 320)
        } else {
            ForEach(localNodes) { n in localNodeCard(n) }
        }
    }

    private func localNodeCard(_ n: LocalProxy) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                DSIconSlot(systemImage: "server.rack")
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(n.name).font(.dsCardName).foregroundStyle(.primary).lineLimit(1)
                        DSProtoTag(type: n.kind.label)
                        if n.forkedFrom != nil {
                            DSKindBadge(text: "已分叉·不再跟随订阅")
                        }
                    }
                    Text("\(n.server):\(n.port)")
                        .font(.dsMonoSm)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: DS.Spacing.s)
                DSIconButton(systemImage: "pencil", help: "编辑") { beginEditLocalNode(n) }
                DSIconButton(systemImage: "trash", tint: DS.Palette.error, help: "删除") {
                    confirmDeleteNode = n.name
                }
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, DS.Spacing.m)
        .dsCardChrome()
    }

    // MARK: 订阅 tab

    @ViewBuilder
    private var subscriptionsContent: some View {
        if providers.isEmpty {
            ContentUnavailable("无 HTTP 订阅 · 点右上角「添加节点」", "icloud")
                .frame(minHeight: 320)
        } else {
            ForEach(providers, id: \.name) { p in subscriptionCard(p) }
        }
    }

    /// 订阅卡 — 原型 08-subscriptions：图标槽 + 名称/节点数徽章 + URL，
    /// 下方流量进度条与到期/更新时间，右侧操作按钮组。
    private func subscriptionCard(_ p: ProviderEntry) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                DSIconSlot(systemImage: "icloud")

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(p.name).font(.dsCardName).foregroundStyle(.primary).lineLimit(1)
                        DSKindBadge(text: "\(p.proxies?.count ?? 0) 节点")
                    }
                    Text(M.engine.proxyProviders().first { $0.name == p.name }?.url ?? "—")
                        .font(.dsMonoSm)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: DS.Spacing.s)

                if busy.contains(p.name) {
                    ProgressView().controlSize(.small)
                } else {
                    DSIconButton(systemImage: "arrow.clockwise", help: "更新") {
                        Task { await updateSubscription(p.name) }
                    }
                    DSIconButton(systemImage: "pencil", help: "编辑") { beginEditSubscription(p.name) }
                    DSIconButton(systemImage: "trash", tint: DS.Palette.error, help: "删除") {
                        confirmDeleteSub = p.name
                    }
                }
            }

            if let nodes = p.proxies, !nodes.isEmpty {
                VStack(spacing: 0) {
                    ForEach(nodes, id: \.name) { node in
                        HStack(spacing: DS.Spacing.s) {
                            DSProtoTag(type: node.type)
                            Text(node.name)
                                .font(.dsBody)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: DS.Spacing.s)
                            DSIconButton(systemImage: "arrow.triangle.branch", help: "分叉为可编辑的本地节点") {
                                forkTarget = (p.name, node.name)
                            }
                        }
                        .padding(.vertical, DS.Spacing.xs)
                        .overlay(alignment: .bottom) { DSRowDivider() }
                    }
                }
                .padding(.top, DS.Spacing.m)
            }

            if let s = p.subscriptionInfo, let total = s.Total, total > 0 {
                let used = (s.Upload ?? 0) + (s.Download ?? 0)
                let frac = min(1, Double(used) / Double(total))
                VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                    HStack(spacing: DS.Spacing.s) {
                        Text("流量 \(fmtBytes(Double(used))) / \(fmtBytes(Double(total)))")
                            .font(.dsCaption).foregroundColor(.secondary)
                        Spacer(minLength: DS.Spacing.s)
                        Text(String(format: "%.0f%%", frac * 100))
                            .font(.dsMonoSm).monospacedDigit()
                            .foregroundColor(frac > 0.85 ? DS.Palette.error : .secondary)
                    }
                    DSBar(progress: frac, tint: frac > 0.85 ? DS.Palette.error : DS.Palette.accent, height: 4)
                }
                .padding(.top, DS.Spacing.m)
            }

            HStack(spacing: DS.Spacing.l) {
                Spacer(minLength: 0)
                if let s = p.subscriptionInfo, let exp = s.Expire, exp > 0 {
                    metaColumn("到期", dateStr(exp))
                }
                if let u = p.updatedAt, !u.hasPrefix("0001") {
                    metaColumn("更新于", String(u.prefix(19)).replacingOccurrences(of: "T", with: " "))
                }
            }
            .padding(.top, DS.Spacing.s)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, DS.Spacing.m)
        .dsCardChrome()
    }

    private func metaColumn(_ label: String, _ value: String) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(label).font(.dsMetaLabel).foregroundColor(DS.Palette.textFaint)
            Text(value).font(.dsMonoSm).monospacedDigit().foregroundColor(.secondary)
        }
    }

    // Add / edit sheet（订阅）
    private var subscriptionSheet: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.l) {
            Text(editSubName == nil ? "添加订阅节点" : "编辑订阅节点").font(.dsCardLabel)
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                Text("名称").font(.dsBody).foregroundColor(.secondary)
                TextField("如 US-Premium（不含空格）", text: $fName)
                    .inputStyle()
                    .font(.dsMono)
                Text("订阅链接").font(.dsBody).foregroundColor(.secondary)
                TextField("https://…", text: $fURL)
                    .inputStyle()
                    .font(.dsMono)
            }
            HStack {
                Button("取消") { showSubSheet = false }
                    .dsButton()
                Spacer()
                Button("保存") { Task { await saveSubscription() } }
                    .dsButton(.prominent)
                    .disabled(fName.trimmingCharacters(in: .whitespaces).isEmpty || !fURL.hasPrefix("http"))
            }
        }.padding(DS.Spacing.xl).frame(width: 460)
    }

    // MARK: 动作 — 订阅

    private func beginAddSubscription() {
        editSubName = nil; fName = ""; fURL = ""
        showSubSheet = true
    }

    private func beginEditSubscription(_ name: String) {
        editSubName = name
        fName = name
        fURL = M.engine.proxyProviders().first { $0.name == name }?.url ?? ""
        showSubSheet = true
    }

    /// Add or rename/update a provider, then persist via the safe (validate+revert) path.
    private func saveSubscription() async {
        let name = fName.trimmingCharacters(in: .whitespaces)
        let url = fURL.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, url.hasPrefix("http") else { return }
        var list = M.engine.proxyProviders()
        if let old = editSubName, let i = list.firstIndex(where: { $0.name == old }) {
            list[i] = (name: name, url: url)
        } else if let i = list.firstIndex(where: { $0.name == name }) {
            list[i] = (name: name, url: url)   // upsert by name
        } else {
            list.append((name: name, url: url))
        }
        showSubSheet = false
        if await M.saveProxyProviders(list) { await reload() }
    }

    private func deleteSubscription(_ name: String) async {
        var list = M.engine.proxyProviders()
        list.removeAll { $0.name == name }
        if await M.saveProxyProviders(list) { await reload() }
    }

    private func updateSubscription(_ name: String) async {
        busy.insert(name)
        do {
            try await M.api.updateProvider(name)
            try? await Task.sleep(nanoseconds: 800_000_000)
            await reload()
            busy.remove(name)
            M.showToast("已更新订阅「\(name)」", kind: .ok)
        } catch {
            busy.remove(name)
            M.showToast("更新订阅「\(name)」失败：\(error.localizedDescription)", kind: .error)
        }
    }

    private func updateAll() async { for p in providers { await updateSubscription(p.name) } }

    private func dateStr(_ unix: Int64) -> String {
        let d = Date(timeIntervalSince1970: TimeInterval(unix))
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: d)
    }

    // MARK: 动作 — 本地节点

    private func beginAddLocalNode() {
        editingNode = nil
        forkPrefill = nil
        showNodeSheet = true
    }

    private func beginEditLocalNode(_ n: LocalProxy) {
        editingNode = n
        forkPrefill = nil
        showNodeSheet = true
    }

    /// 把订阅节点分叉成本地节点草稿：从该订阅的本地缓存文件里找出这个节点原始
    /// 的分享链接，解析出完整连接参数。找不到缓存、或链接解析失败（协议/传输
    /// 方式暂不支持）就明确提示失败，不生成一个参数残缺、看着正常实际连不上的
    /// "假节点"。
    private func beginForkNode(provider: String, node: String) {
        guard let link = M.engine.shareLinkForProviderNode(providerName: provider, nodeName: node),
              var parsed = ShareLinkParser.parse(link) else {
            M.showToast("无法分叉「\(node)」——找不到原始参数，或协议/传输方式暂不支持", kind: .error)
            return
        }
        parsed.forkedFrom = node
        // 分叉后的名字要和原节点区分开：一来避免和订阅池里的同名节点冲突，
        // 二来节点列表里一眼能看出这是分叉出来的，不是订阅本身的节点。
        parsed.name = node + " (本地副本)"
        editingNode = nil
        forkPrefill = parsed
        tab = .local   // 切到本地节点 tab，保存后用户能立刻在列表里看到它
        showNodeSheet = true
    }

    private func saveNode(_ proxy: LocalProxy, extraLines: [String], addToGroup group: String?) async {
        showNodeSheet = false
        if await M.saveLocalProxy(proxy, extraLines: extraLines, addToGroup: group) {
            await reloadLocalNodes()
        }
    }

    private func deleteNode(_ name: String) async {
        if await M.deleteLocalProxy(named: name) {
            await reloadLocalNodes()
        }
    }

    // MARK: 加载

    private func reload() async {
        await reloadSubscriptions()
        await reloadLocalNodes()
        // 本地节点表单的"接入策略组"选择器依赖 M.groups——这个页面此前从不主动
        // 刷新它，如果用户没先去过「代理」页就直接来这添加本地节点，选择器可能
        // 是空的：节点写进了配置，但没接入任何组，变成一个选不到、用不了的死节点。
        await M.refreshProxies()
    }

    private func reloadSubscriptions() async {
        guard let p = try? await M.api.fetchProviders() else { return }
        providers = p.providers.values.filter { $0.vehicleType == "HTTP" }.sorted { $0.name < $1.name }
    }

    private func reloadLocalNodes() async {
        let entries = M.engine.localProxies()
        localNodes = entries.compactMap(LocalProxy.from).sorted { $0.name < $1.name }
        localExtraLines = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0.extraLines) })
    }
}

// MARK: - 本地节点新增/编辑表单

/// `existing == nil` 是新增：可选协议、可粘贴分享链接自动解析、需要选接入的策略组。
/// `existing != nil` 是编辑：协议类型和名称锁定不可改——名称是配置里的存储 key，
/// 改名等于"删旧建新 + 搬迁所有策略组引用"，这条路径目前没有实现，与其做出一个
/// 看起来能改、实际会留下悬空引用或重复条目的表单，不如先锁死，明确地不支持。
struct NodeFormSheet: View {
    @Environment(\.dismiss) var dismiss
    let existing: LocalProxy?
    let extraLines: [String]
    let defaultGroup: String?
    let availableGroups: [String]
    let onSave: (LocalProxy, [String], String?) -> Void

    @State private var proxy: LocalProxy
    @State private var shareLink = ""
    @State private var parseError = false
    @State private var selectedGroup: String

    /// `existing` 决定"这是编辑已有节点"（锁定名称/协议、隐藏接入组选择器，
    /// 因为组成员关系已经存在了）。`prefill` 只是给一个全新节点预填字段——
    /// fork-on-edit 用这个：分叉出来的节点在配置里还不存在，必须走"新增"那一套
    /// （名称可改、要选接入哪个策略组），只是初始值不是空的，是从订阅节点解析来的。
    /// 两者不能共用同一个参数，传错的话分叉出的节点会因为 isNew 判断成 false
    /// 而跳过接入策略组这一步，变成一个写进配置但选不到、用不了的死节点。
    init(existing: LocalProxy?, prefill: LocalProxy? = nil, extraLines: [String], defaultGroup: String?,
         availableGroups: [String], onSave: @escaping (LocalProxy, [String], String?) -> Void) {
        self.existing = existing
        self.extraLines = extraLines
        self.defaultGroup = defaultGroup
        self.availableGroups = availableGroups
        self.onSave = onSave
        _proxy = State(initialValue: existing ?? prefill ?? LocalProxy())
        _selectedGroup = State(initialValue: defaultGroup ?? availableGroups.first ?? "")
    }

    private var isNew: Bool { existing == nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.l) {
                Text(proxy.forkedFrom != nil ? "分叉为本地节点" : (isNew ? "添加本地节点" : "编辑本地节点"))
                    .font(.dsCardLabel)
                if let origin = proxy.forkedFrom {
                    Text("参数取自订阅节点「\(origin)」，保存后成为独立副本，不再随订阅刷新更新。")
                        .font(.dsCaption).foregroundColor(.secondary)
                }

                if isNew {
                    VStack(alignment: .leading, spacing: DS.Spacing.s) {
                        Text("分享链接（可选）").font(.dsBody).foregroundColor(.secondary)
                        HStack(spacing: DS.Spacing.s) {
                            TextField("vmess:// vless:// trojan:// ss:// hysteria2://", text: $shareLink)
                                .inputStyle().font(.dsMono)
                            Button("解析") { parseShareLink() }
                                .dsButton()
                                .disabled(shareLink.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                        if parseError {
                            Text("解析失败——可能是不支持的协议，或链接要求 ws/gRPC 等传输层封装（暂不支持）。请手动填写下方字段。")
                                .font(.dsCaption).foregroundColor(DS.Palette.error)
                        }
                    }
                }

                VStack(alignment: .leading, spacing: DS.Spacing.s) {
                    Text("协议").font(.dsBody).foregroundColor(.secondary)
                    if isNew {
                        DSMenuPicker(selection: $proxy.kind,
                                     choices: LocalProxy.Kind.allCases.map { DSChoice($0.label, $0) })
                    } else {
                        Text(proxy.kind.label).font(.dsBodySemibold)
                    }

                    Text("名称").font(.dsBody).foregroundColor(.secondary)
                    TextField("节点名称（唯一）", text: $proxy.name).inputStyle().font(.dsMono)
                        .disabled(!isNew)

                    HStack(alignment: .top, spacing: DS.Spacing.s) {
                        VStack(alignment: .leading, spacing: DS.Spacing.s) {
                            Text("服务器").font(.dsBody).foregroundColor(.secondary)
                            TextField("server", text: $proxy.server).inputStyle().font(.dsMono)
                        }
                        VStack(alignment: .leading, spacing: DS.Spacing.s) {
                            Text("端口").font(.dsBody).foregroundColor(.secondary)
                            TextField("port", text: $proxy.port).inputStyle().font(.dsMono)
                        }
                        .frame(width: 110)
                    }

                    protocolFields

                    DSSwitchRow(title: "允许 UDP", isOn: $proxy.udp)

                    if isNew, !availableGroups.isEmpty {
                        Text("接入策略组").font(.dsBody).foregroundColor(.secondary)
                        DSMenuPicker(selection: $selectedGroup, choices: availableGroups.map { DSChoice($0, $0) })
                    }
                }

                HStack {
                    Button("取消") { dismiss() }.dsButton()
                    Spacer()
                    Button("保存") {
                        onSave(proxy, extraLines, isNew ? (selectedGroup.isEmpty ? nil : selectedGroup) : nil)
                    }
                    .dsButton(.prominent)
                    .disabled(!isValid)
                }
            }
            .padding(DS.Spacing.xl)
        }
        .frame(width: 480, height: 600)
    }

    @ViewBuilder
    private var protocolFields: some View {
        switch proxy.kind {
        case .vmess:
            labeledField("UUID", $proxy.uuid)
            HStack(spacing: DS.Spacing.s) {
                labeledFieldBlock("Alter ID") { TextField("0", text: $proxy.alterId).inputStyle().font(.dsMono) }
                labeledFieldBlock("加密方式") { TextField("auto", text: $proxy.cipher).inputStyle().font(.dsMono) }
            }
            DSSwitchRow(title: "启用 TLS", isOn: $proxy.tls)
            if proxy.tls { labeledField("SNI", $proxy.sni) }
        case .vless:
            labeledField("UUID", $proxy.uuid)
            labeledField("Flow（可选，如 xtls-rprx-vision）", $proxy.flow)
            labeledField("SNI", $proxy.sni)
            DSSwitchRow(title: "跳过证书校验", isOn: $proxy.skipCertVerify)
            // REALITY：public key 和 short id 缺一不可，两个都填才会写出
            // reality-opts（见 LocalProxy.toEntry）；只填一个等于没填。
            labeledField("REALITY Public Key（可选）", $proxy.publicKey)
            labeledField("REALITY Short ID（可选）", $proxy.shortId)
            labeledField("指纹伪装（可选，默认 chrome）", $proxy.fingerprint)
        case .trojan:
            labeledField("密码", $proxy.password)
            labeledField("SNI", $proxy.sni)
            DSSwitchRow(title: "跳过证书校验", isOn: $proxy.skipCertVerify)
        case .ss:
            labeledField("密码", $proxy.password)
            labeledField("加密方式（如 aes-256-gcm）", $proxy.cipher)
        case .hysteria2:
            labeledField("密码", $proxy.password)
            labeledField("SNI", $proxy.sni)
            DSSwitchRow(title: "跳过证书校验", isOn: $proxy.skipCertVerify)
        }
    }

    private func labeledField(_ label: String, _ binding: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            Text(label).font(.dsBody).foregroundColor(.secondary)
            TextField("", text: binding).inputStyle().font(.dsMono)
        }
    }

    private func labeledFieldBlock<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            Text(label).font(.dsBody).foregroundColor(.secondary)
            content()
        }
    }

    private var isValid: Bool {
        guard !proxy.name.trimmingCharacters(in: .whitespaces).isEmpty,
              !proxy.server.trimmingCharacters(in: .whitespaces).isEmpty,
              let portNum = Int(proxy.port), portNum > 0, portNum <= 65535 else { return false }
        switch proxy.kind {
        case .vmess, .vless: return !proxy.uuid.trimmingCharacters(in: .whitespaces).isEmpty
        case .trojan, .ss, .hysteria2: return !proxy.password.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    private func parseShareLink() {
        if let parsed = ShareLinkParser.parse(shareLink.trimmingCharacters(in: .whitespacesAndNewlines)) {
            proxy = parsed
            parseError = false
        } else {
            parseError = true
        }
    }
}
