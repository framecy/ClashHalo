import SwiftUI

// MARK: - Subscriptions (proxy providers)

/// 打开弹窗那一刻的快照。用 `.sheet(item:)` 承载初值：SwiftUI 只在视图身份
/// 首次出现时采用 `@State` 初值，复用同一身份会让「编辑」沿用上一次的勾选
/// （规则页 2026-10-20 的同款根因）。
struct SubscriptionDraft: Identifiable {
    enum Mode { case add, editFull, editGroups }
    let id = UUID()
    let mode: Mode
    let name: String
    let url: String
    let selected: Set<String>
    let originalName: String?
}

struct SubscriptionsPage: View {
    @EnvironmentObject var M: AppModel
    @State private var providers: [ProviderEntry] = []
    /// 磁盘 config.yaml 里的订阅清单，读取不需要内核。内核未连接 / 配置未应用时
    /// 订阅依然要能添加、编辑、删除——旧实现整页被「内核未连接」空态挡住。
    @State private var localProviders: [(name: String, url: String)] = []
    @State private var busy: Set<String> = []
    /// UI-6：loading ≠ empty——首次 reload 完成前不画「无订阅」空态。
    @State private var loaded = false
    /// P3：「全部刷新节点」重入守卫，防两条更新链并行互相覆盖 reload。
    @State private var updatingAll = false
    @State private var draft: SubscriptionDraft?
    @State private var confirmDelete: String? = nil
    /// provider 名 → 显式引用它的策略组名（`use:`）。随 reload 一起刷新。
    @State private var memberships: [String: [String]] = [:]
    /// 配置里的策略组清单（含 include-all 标记），弹窗与卡片共用。
    @State private var groups: [ProviderGroupBinding.Group] = []
    /// 已被 App 转成本地文件的 provider（`type: file`）。这些的节点由 App 维护，
    /// 编辑 URL 没有意义，也不该再走 http 模板重写。
    @State private var localFileProviders: Set<String> = []

    /// 以磁盘清单为准渲染；内核在线时把节点数 / 协议 / 流量等运行时信息补上。
    /// 只用 `/providers` 的数据会让「配置里有、内核还没加载」的订阅整个消失。
    private var displayed: [ProviderEntry] {
        localProviders.map { local in
            providers.first { $0.name == local.name }
                ?? ProviderEntry(name: local.name, type: "Proxy", vehicleType: "HTTP",
                                 proxies: nil, updatedAt: nil, subscriptionInfo: nil)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            PageToolbar {
                // P2-2（方案 B）：本页刷的是**内核里的 proxy-provider 缓存**，不重写
                // 磁盘配置文件（那是配置页的事）。文案必须让两者分得开。
                Button { Task { await updateAll() } } label: { Label("全部刷新节点", systemImage: "arrow.clockwise") }
                    .dsButton()
                    .disabled(updatingAll || !M.reachable)
                if !M.store.providerSources.isEmpty {
                    Button { Task { await M.refreshLocalProviders() } } label: {
                        Label("刷新本地订阅", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .dsButton()
                    .disabled(updatingAll || M.engine.isBusy)
                }
                Button { openAdd() } label: { Label("添加订阅", systemImage: "plus") }
                    .dsButton(.prominent)
            }
            if !loaded {
                VStack(spacing: DS.Spacing.m) {
                    ProgressView().controlSize(.small)
                    Text("正在加载订阅…")
                        .font(.dsBody).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if displayed.isEmpty {
                ContentUnavailable("还没有订阅 · 点右上角「添加订阅」", "icloud")
            } else {
                ScrollView {
                    VStack(spacing: DS.Spacing.m) {
                        if !M.reachable {
                            // 内核未连接只影响「节点信息」，不该挡住订阅管理。
                            HStack(spacing: DS.Spacing.s) {
                                Image(systemName: "exclamationmark.triangle")
                                    .font(DS.Icon.font(DS.Icon.md, weight: .medium))
                                    .symbolRenderingMode(.monochrome)
                                    .foregroundStyle(DS.Palette.warn)
                                Text("内核未连接，节点信息不可用；订阅仍可添加、编辑和删除，改动会在内核启动后生效。")
                                    .font(.dsBody).foregroundStyle(.secondary)
                                Spacer(minLength: 0)
                                Button("重试") { Task { await M.reconnect(); await reload() } }
                                    .dsButton()
                            }
                            .padding(DS.Spacing.m)
                            .dsCardChrome()
                        }
                        ForEach(displayed, id: \.name) { p in card(p) }
                    }
                    .padding(.horizontal, DS.Layout.pageContentInset)
                    .padding(.top, DS.Spacing.l)
                    .padding(.bottom, DS.Spacing.xxl)
                }
            }
        }
        .task { await reload() }
        // UI-6：内核恢复后自动重取，不需要切走再切回。
        .onChange(of: M.reachable) { _, up in
            if up { Task { await reload() } }
        }
        .sheet(item: $draft) { d in
            SubscriptionSheet(
                draft: d,
                groups: groups,
                onCancel: { draft = nil },
                onSave: { name, url, selected in
                    await save(name: name, url: url, selected: selected,
                               mode: d.mode, originalName: d.originalName)
                }
            )
        }
        .confirmationDialog("删除订阅「\(confirmDelete ?? "")」？", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }), titleVisibility: .visible) {
            Button("删除", role: .destructive) { if let n = confirmDelete { Task { await delete(n) } }; confirmDelete = nil }
        } message: {
            if let n = confirmDelete, let refs = memberships[n], !refs.isEmpty {
                Text("将从配置中移除该 proxy-provider，并从 \(refs.count) 个策略组（\(refs.joined(separator: "、"))) 中移除引用。")
            } else {
                Text("将从配置中移除该 proxy-provider 及其在策略组中的引用。")
            }
        }
    }

    // MARK: - Card

    private func card(_ p: ProviderEntry) -> some View {
        Card {
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                HStack(spacing: DS.Spacing.s) {
                    Image(systemName: "icloud.fill").foregroundColor(DS.Palette.accent)
                    Text(p.name).font(.dsBodySemibold)
                    Text("\(p.proxies?.count ?? 0) 节点").font(.dsBody)
                        .padding(.horizontal, DS.Spacing.xs)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(DS.Palette.hairline))
                    if localFileProviders.contains(p.name) {
                        Text("本地")
                            .font(.dsCaption)
                            .padding(.horizontal, DS.Spacing.xs)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(DS.Palette.hairline))
                            .help("节点由 App 下载并转换成本地文件，内核直接读取")
                    }
                    Spacer(minLength: 0)
                    if busy.contains(p.name) {
                        ProgressView().controlSize(.small)
                    } else {
                        Button { Task { await update(p.name) } } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.borderless).help("刷新内核节点（不重写配置文件）")
                            .disabled(!M.reachable)
                        if localFileProviders.contains(p.name) {
                            // 本地 provider 的 URL 已经不存在（源地址记在 provider-sources.json），
                            // 编辑框会显示空值并让用户以为订阅坏了。
                            Button { Task { await M.refreshLocalProviders() } } label: {
                                Image(systemName: "arrow.triangle.2.circlepath")
                            }
                            .buttonStyle(.borderless)
                            .help("重新下载并转换这条本地订阅")
                            .disabled(M.engine.isBusy)
                        } else {
                            Button { openEdit(p.name) } label: { Image(systemName: "pencil") }
                                .buttonStyle(.borderless).help("编辑订阅（名称 / 链接 / 策略组）")
                            // base64 节点订阅（.txt）内核解析不了，转成本地文件才有节点。
                            Button { Task { await M.convertProviderToLocalFile(name: p.name) } } label: {
                                Image(systemName: "square.and.arrow.down")
                            }
                            .buttonStyle(.borderless)
                            .help("转为本地订阅（mihomo 不认 base64 订阅内容）")
                            .disabled(M.engine.isBusy)
                        }
                        Button { confirmDelete = p.name } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).foregroundColor(DS.Palette.error).help("删除")
                    }
                }
                // 协议分布：一眼看出这份订阅是什么货色（VLESS 61 · HYSTERIA2 25 · SS 2）。
                // `proxies` 为 nil（provider 还没下载完）或为空时不显示——显示「0」会
                // 被读成订阅坏了，而事实是还没拉取。
                if let proxies = p.proxies, !proxies.isEmpty {
                    let summary = ProviderProtocols.summarize(proxies.map { $0.type })
                    if !summary.isEmpty {
                        Text(summary.text)
                            .font(.dsMono)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .help("按协议统计的节点数，合计 \(summary.total) 个")
                    }
                }
                groupRow(p)
                if let s = p.subscriptionInfo, let total = s.Total, total > 0 {
                    let used = (s.Upload ?? 0) + (s.Download ?? 0)
                    let frac = min(1, Double(used) / Double(total))
                    VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                        ProgressView(value: frac).tint(frac > 0.85 ? DS.Palette.error : DS.Palette.accent)
                        HStack {
                            Text("\(fmtBytes(Double(used))) / \(fmtBytes(Double(total)))").font(.dsMono).foregroundColor(.secondary)
                            Spacer(minLength: 0)
                            if let exp = s.Expire, exp > 0 {
                                Text("到期 " + dateStr(exp)).font(.dsMono).foregroundColor(.secondary)
                            }
                        }
                    }
                }
                if let u = p.updatedAt, !u.hasPrefix("0001") {
                    Text("更新于 " + String(u.prefix(19)).replacingOccurrences(of: "T", with: " "))
                        .font(.dsBody).foregroundColor(.secondary)
                }
            }
        }
    }

    /// 归属行：显式 `use:` 的组名 chips + 「编辑分组」；一个组都没有时给出可操作提示。
    @ViewBuilder
    private func groupRow(_ p: ProviderEntry) -> some View {
        let refs = memberships[p.name] ?? []
        let includeAll = groups.filter(\.includesAllProviders).map(\.name)
        if refs.isEmpty && includeAll.isEmpty {
            HStack(spacing: DS.Spacing.s) {
                Label("尚未加入任何策略组，节点不会出现在「代理节点」页",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.dsCaption)
                    .foregroundColor(DS.Palette.warn)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("选择策略组") { openGroups(p.name) }
                    .dsButton(.plain)
                    .disabled(M.engine.isBusy)
            }
        } else {
            HStack(spacing: DS.Spacing.s) {
                Text("策略组").font(.dsCaption).foregroundColor(.secondary)
                if refs.isEmpty {
                    // 仅靠 include-all-providers 生效：说清来源，不误报成用户勾选。
                    Text("已由 " + includeAll.joined(separator: "、") + " 自动包含")
                        .font(.dsCaption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                } else {
                    let shown = refs.prefix(3)
                    Text(shown.joined(separator: " · "))
                        .font(.dsCaption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    if refs.count > shown.count {
                        Text("+\(refs.count - shown.count)")
                            .font(.dsCaption)
                            .foregroundColor(.secondary)
                            .help(refs.joined(separator: "、"))
                    }
                }
                Spacer(minLength: 0)
                Button("编辑分组") { openGroups(p.name) }
                    .dsButton(.plain)
                    .disabled(M.engine.isBusy || busy.contains(p.name))
            }
        }
    }

    // MARK: - Drafts

    private func openAdd() {
        // 「默认全选」：勾上全部可加入的组；include-all-providers 组置灰展示。
        draft = SubscriptionDraft(mode: .add, name: "", url: "",
                                  selected: Set(groups.filter { !$0.includesAllProviders }.map(\.name)),
                                  originalName: nil)
    }

    private func openGroups(_ name: String) {
        draft = SubscriptionDraft(mode: .editGroups, name: name, url: "", selected: Set(memberships[name] ?? []),
                                  originalName: name)
    }

    private func openEdit(_ name: String) {
        draft = SubscriptionDraft(mode: .editFull, name: name,
                                  url: M.engine.proxyProviders().first { $0.name == name }?.url ?? "",
                                  selected: Set(memberships[name] ?? []),
                                  originalName: name)
    }

    // MARK: - Persist

    private func save(name rawName: String, url rawURL: String, selected: Set<String>,
                      mode: SubscriptionDraft.Mode, originalName: String?) async -> String? {
        guard !M.engine.isBusy else { return "内核正忙，请稍后再试" }
        let name = rawName.trimmingCharacters(in: .whitespaces)
        let url = rawURL.trimmingCharacters(in: .whitespaces)
        var list = M.engine.proxyProviders()

        if mode != .editGroups {
            guard !name.isEmpty else { return "请填写订阅名称" }
            guard url.hasPrefix("http") else { return "订阅链接必须以 http 开头" }
            let conflict = list.contains { $0.name == name && $0.name != originalName }
            if conflict { return "已存在同名订阅「\(name)」，请换个名字" }
            if let old = originalName, let i = list.firstIndex(where: { $0.name == old }) {
                list[i] = (name: name, url: url)
            } else if let i = list.firstIndex(where: { $0.name == name }) {
                list[i] = (name: name, url: url)   // upsert by name
            } else {
                list.append((name: name, url: url))
            }
        }

        // 以保存那一刻的磁盘配置为准：弹窗打开期间组可能被外部删掉。
        let text = (try? String(contentsOfFile: M.engine.configFilePath, encoding: .utf8)) ?? ""
        let liveGroups = ProviderGroupBinding.groups(in: text)
        guard !liveGroups.isEmpty else {
            return "配置里还没有策略组。请先导入含 proxy-groups 的配置，或在 config.yaml 添加策略组后重试。"
        }
        let selectable = Set(liveGroups.filter { !$0.includesAllProviders }.map(\.name))
        let chosen = selected.intersection(selectable)
        let hasIncludeAll = liveGroups.contains(where: \.includesAllProviders)
        guard !chosen.isEmpty || hasIncludeAll else {
            return "至少选择一个策略组；不选的话订阅节点不会出现在「代理节点」页。"
        }

        let targetName = mode == .editGroups ? (originalName ?? name) : name
        var renamed: [String: String] = [:]
        if mode != .editGroups, let old = originalName, old != name { renamed[old] = name }

        let ok = await M.saveProxyProviders(list, memberships: [targetName: chosen], renamed: renamed)
        await reload()
        if ok {
            draft = nil
            let count = chosen.count
            M.showToast(count > 0
                        ? "已保存订阅「\(name)」，加入 \(count) 个策略组"
                        : "已保存订阅「\(name)」，节点已随 include-all-providers 组生效",
                        kind: .ok)
            return nil
        }
        return "保存失败，已回滚；请检查配置后重试"
    }

    private func delete(_ name: String) async {
        var list = M.engine.proxyProviders()
        list.removeAll { $0.name == name }
        _ = await M.saveProxyProviders(list)
        // 源地址记录跟着一起清：留着的唯一后果是「刷新本地订阅」去下载一个已经
        // 不存在的 provider，白等一轮网络超时。
        M.store.removeProviderSource(name: name)
        await reload()
    }

    private func reload() async {
        // 磁盘清单先落地：即使内核不可达、fetchProviders 抛错，页面也有东西可管。
        localProviders = M.engine.proxyProviders()
        let configText = (try? String(contentsOfFile: M.engine.configFilePath, encoding: .utf8)) ?? ""
        localFileProviders = Set(localProviders.map(\.name).filter {
            ProviderRewrite.isFileProvider(configText, name: $0)
        })
        groups = ProviderGroupBinding.groups(in: configText)
        memberships = ProviderGroupBinding.membership(in: configText)
        defer { loaded = true }
        guard let p = try? await M.api.fetchProviders() else {
            providers = []
            return
        }
        // HTTP 与 File 都要留在运行时清单里：转成本地 provider 的订阅（type: file）
        // 节点由 App 维护，但节点数 / 协议分布只存在于 `/providers` 的返回里。
        // 只留 HTTP 会让这类订阅回落到 displayed 的兜底条目，卡片显示「0 节点」
        // ——看上去就像整条订阅挂了（2026-11-17 现场）。
        providers = p.providers.values
            .filter { $0.vehicleType == "HTTP" || $0.vehicleType == "File" }
            .sorted { $0.name < $1.name }
    }
    private func update(_ name: String) async {
        busy.insert(name)
        do {
            try await M.api.updateProvider(name)
        } catch {
            // 这里原来用 `try?` 把失败吞掉，再无条件弹绿色「已更新订阅」——节点一个没变
            // 也报成功。失败时如实报错并**不** reload()：更新没成功，重取只会把同一份
            // 旧节点列表再画一遍，看起来像"刷新过了"。
            M.logKernel("[Subscriptions] 更新订阅「\(name)」失败: \(error.localizedDescription)")
            busy.remove(name)
            M.showToast("刷新节点「\(name)」失败，已保留原节点列表", kind: .error)
            return
        }
        try? await Task.sleep(nanoseconds: 800_000_000)
        await reload(); busy.remove(name)
        M.showToast("内核节点「\(name)」已刷新", kind: .ok)
    }
    private func updateAll() async {
        // P3：重入守卫——全部刷新进行中再点一次会并行跑两条更新链，
        // toast 互相覆盖、reload 互相打架。
        guard !updatingAll else { return }
        updatingAll = true
        defer { updatingAll = false }
        // 本地 provider 的节点文件由 App 维护，内核 update 只是重读同一份文件；
        // 真正的「重新下载源地址」是「刷新本地订阅」。放进来只会多一次无效请求。
        for p in providers where !localFileProviders.contains(p.name) { await update(p.name) }
    }
    // 到期日只渲染为墙上日期；formatter 构建一次（LogsPage.logDF 同款写法），
    // 不随每行每次 body 求值重建（DateFormatter 初始化是重对象操作）。
    private static let dateDF: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private func dateStr(_ unix: Int64) -> String {
        Self.dateDF.string(from: Date(timeIntervalSince1970: TimeInterval(unix)))
    }
}

// MARK: - Add / edit sheet

private struct SubscriptionSheet: View {
    let draft: SubscriptionDraft
    let groups: [ProviderGroupBinding.Group]
    let onCancel: () -> Void
    let onSave: (_ name: String, _ url: String, _ selected: Set<String>) async -> String?

    @State private var name: String
    @State private var url: String
    @State private var selected: Set<String>
    @State private var search = ""
    @State private var error: String?
    @State private var saving = false

    init(draft: SubscriptionDraft,
         groups: [ProviderGroupBinding.Group],
         onCancel: @escaping () -> Void,
         onSave: @escaping (_ name: String, _ url: String, _ selected: Set<String>) async -> String?) {
        self.draft = draft
        self.groups = groups
        self.onCancel = onCancel
        self.onSave = onSave
        _name = State(initialValue: draft.name)
        _url = State(initialValue: draft.url)
        _selected = State(initialValue: draft.selected)
    }

    private var canEditName: Bool { draft.mode != .editGroups }
    private var selectableGroups: [ProviderGroupBinding.Group] {
        groups.filter { !$0.includesAllProviders }
    }
    private var includeAllGroups: [ProviderGroupBinding.Group] {
        groups.filter(\.includesAllProviders)
    }
    private var visibleGroups: [ProviderGroupBinding.Group] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return groups }
        return groups.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }
    private var chosenCount: Int { selected.intersection(Set(selectableGroups.map(\.name))).count }
    private var canSave: Bool {
        guard !groups.isEmpty, !saving else { return false }
        if canEditName {
            guard !name.trimmingCharacters(in: .whitespaces).isEmpty,
                  url.trimmingCharacters(in: .whitespaces).hasPrefix("http") else { return false }
        }
        return chosenCount > 0 || !includeAllGroups.isEmpty
    }
    /// 取消某个组后它会失去唯一的订阅来源（保存时会自动补 DIRECT），提前说清楚。
    private var emptyGroupWarning: String? {
        guard draft.mode != .add, let original = draft.originalName else { return nil }
        for g in groups where !g.includesAllProviders && !g.includesAllProxies {
            guard !selected.contains(g.name), g.proxyCount == 0,
                  g.providers.filter({ $0 != original }).isEmpty,
                  g.providers.contains(original) else { continue }
            return "取消后「\(g.name)」将没有节点来源，保存时会自动补 DIRECT"
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.l) {
            Text(title).font(.dsCardLabel)

            if canEditName {
                VStack(alignment: .leading, spacing: DS.Spacing.s) {
                    Text("名称").font(.dsBody).foregroundColor(.secondary)
                    TextField("如 US-Premium（不含空格）", text: $name)
                        .inputStyle()
                        .font(.dsMono)
                        .onSubmit { Task { await submit() } }
                    Text("订阅链接").font(.dsBody).foregroundColor(.secondary)
                    TextField("https://…", text: $url)
                        .inputStyle()
                        .font(.dsMono)
                        .onSubmit { Task { await submit() } }
                }
            } else {
                HStack(spacing: DS.Spacing.s) {
                    Text(name).font(.dsBodySemibold)
                    Text("只修改策略组归属，名称与链接保持不变")
                        .font(.dsCaption).foregroundColor(.secondary)
                    Spacer(minLength: 0)
                }
            }

            groupPicker
            if let warning = emptyGroupWarning {
                Text(warning)
                    .font(.dsCaption)
                    .foregroundColor(DS.Palette.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("取消") { onCancel() }
                    .dsButton()
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button("保存") { Task { await submit() } }
                    .dsButton(.prominent)
                    .disabled(!canSave)
                    .keyboardShortcut(.defaultAction)
            }

            // 固定占位：出现/消失不改变弹窗高度（design.md §6.4）。
            Text(error ?? " ")
                .font(.dsBody)
                .foregroundColor(DS.Palette.error)
                .lineLimit(2)
                .frame(minHeight: 16, alignment: .leading)
        }
        .padding(DS.Spacing.xl)
        .frame(width: 520)
        .onChange(of: name) { _, _ in error = nil }
        .onChange(of: url) { _, _ in error = nil }
        .onChange(of: selected) { _, _ in error = nil }
    }

    private var title: String {
        switch draft.mode {
        case .add: return "添加订阅"
        case .editFull: return "编辑订阅"
        case .editGroups: return "编辑策略组归属"
        }
    }

    @ViewBuilder
    private var groupPicker: some View {
        if groups.isEmpty {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                Label("配置里还没有策略组", systemImage: "exclamationmark.triangle.fill")
                    .font(.dsBodySemibold)
                    .foregroundColor(DS.Palette.warn)
                Text("订阅节点必须加入至少一个策略组，才能在「代理节点」页使用。请先导入含 proxy-groups 的配置，或在 config.yaml 添加策略组后回到本页重试。")
                    .font(.dsBody)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(DS.Spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.Shape.control().fill(DS.Palette.controlBg))
            .overlay(DS.Shape.control().stroke(DS.Palette.border, lineWidth: 1))
        } else {
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                HStack(spacing: DS.Spacing.s) {
                    Text("加入策略组").font(.dsBodySemibold)
                    Text("已选 \(chosenCount) / \(selectableGroups.count)")
                        .font(.dsCaption)
                        .foregroundColor(.secondary)
                    Spacer(minLength: 0)
                    Button("全选") { selected.formUnion(selectableGroups.map(\.name)) }
                        .dsButton(.plain)
                    Button("反选") {
                        for g in selectableGroups {
                            if selected.contains(g.name) { selected.remove(g.name) }
                            else { selected.insert(g.name) }
                        }
                    }
                    .dsButton(.plain)
                    Button("清空") { selected.subtract(Set(selectableGroups.map(\.name))) }
                        .dsButton(.plain)
                }
                if groups.count > 8 {
                    TextField("搜索策略组", text: $search)
                        .inputStyle()
                        .font(.dsBody)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(visibleGroups, id: \.name) { g in
                            HStack(spacing: DS.Spacing.s) {
                                Toggle("", isOn: binding(for: g))
                                    .labelsHidden()
                                    .toggleStyle(.checkbox)
                                    .disabled(g.includesAllProviders)
                                Text(g.name)
                                    .font(.dsBody)
                                    .lineLimit(1)
                                Spacer(minLength: DS.Spacing.s)
                                if let caption = caption(for: g) {
                                    Text(caption)
                                        .font(.dsCaption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .padding(.vertical, DS.Spacing.xs)
                            .contentShape(Rectangle())
                        }
                    }
                    .padding(.horizontal, DS.Spacing.s)
                    .padding(.vertical, DS.Spacing.xs)
                }
                .frame(maxHeight: 200)
                .background(DS.Shape.control().fill(DS.Palette.controlBg))
                .overlay(DS.Shape.control().stroke(DS.Palette.border, lineWidth: 1))
                if includeAllGroups.isEmpty {
                    // 固定占位：提示出现/消失不改变弹窗高度。
                    Text(chosenCount == 0
                         ? "至少选择一个策略组；不选的话订阅节点不会出现在「代理节点」页。"
                         : " ")
                        .font(.dsCaption)
                        .foregroundColor(chosenCount == 0 ? DS.Palette.error : .clear)
                        .frame(minHeight: 14, alignment: .leading)
                }
            }
        }
    }

    private func binding(for g: ProviderGroupBinding.Group) -> Binding<Bool> {
        Binding(
            get: { g.includesAllProviders || selected.contains(g.name) },
            set: { on in
                guard !g.includesAllProviders else { return }
                if on { selected.insert(g.name) } else { selected.remove(g.name) }
            }
        )
    }

    private func caption(for g: ProviderGroupBinding.Group) -> String? {
        if g.includesAllProviders { return "已包含全部订阅" }
        if g.includesAllProxies { return "已包含全部普通节点（不含订阅）" }
        guard !g.providers.isEmpty else { return nil }
        return "已有 \(g.providers.count) 个订阅"
    }

    private func submit() async {
        guard canSave else { return }
        saving = true
        defer { saving = false }
        if let err = await onSave(name, url, selected) {
            error = err
        }
    }
}
