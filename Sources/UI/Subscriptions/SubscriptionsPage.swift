import SwiftUI

// MARK: - Subscriptions (proxy providers)

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
    @State private var showSheet = false
    @State private var editName: String? = nil   // nil = add
    @State private var fName = ""
    @State private var fURL = ""
    @State private var confirmDelete: String? = nil
    /// provider 名 → 被多少个策略组 `use:` 引用。随 reload 一起刷新（读 config.yaml 行扫描）。
    @State private var usageCounts: [String: Int] = [:]
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
                Button { editName = nil; fName = ""; fURL = ""; showSheet = true } label: { Label("添加订阅", systemImage: "plus") }
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
                ContentUnavailable("无 HTTP 订阅 · 点右上角「添加订阅」", "icloud")
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
        .sheet(isPresented: $showSheet) { providerSheet }
        .confirmationDialog("删除订阅「\(confirmDelete ?? "")」？", isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } }), titleVisibility: .visible) {
            Button("删除", role: .destructive) { if let n = confirmDelete { Task { await delete(n) } }; confirmDelete = nil }
        } message: { Text("将从配置中移除该 proxy-provider 及其在策略组中的引用。") }
    }

    // Add / edit sheet
    private var providerSheet: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.l) {
            Text(editName == nil ? "添加订阅" : "编辑订阅").font(.dsCardLabel)
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                Text("名称").font(.dsBody).foregroundColor(.secondary)
                TextField("如 US-Premium（不含空格）", text: $fName)
                    .inputStyle()
                    .font(.dsMono)
                    .onSubmit { Task { await save() } }
                Text("订阅链接").font(.dsBody).foregroundColor(.secondary)
                TextField("https://…", text: $fURL)
                    .inputStyle()
                    .font(.dsMono)
                    .onSubmit { Task { await save() } }
            }
            HStack {
                Button("取消") { showSheet = false }
                    .dsButton()

                Spacer()
                Button("保存") { Task { await save() } }
                    .dsButton(.prominent)
                    .disabled(fName.trimmingCharacters(in: .whitespaces).isEmpty || !fURL.hasPrefix("http"))
                    .keyboardShortcut(.defaultAction)
            }
        }.padding(DS.Spacing.xl).frame(width: 460)
    }

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
                            Button { beginEdit(p.name) } label: { Image(systemName: "pencil") }
                                .buttonStyle(.borderless).help("编辑")
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
                // 被几个策略组 use: 引用。N=0 时节点不会出现在代理节点页——
                // 用户删掉引用后只会看到「订阅有节点、代理节点页却没有」，这里先说清。
                let refs = usageCounts[p.name] ?? 0
                if refs == 0 {
                    Label("此订阅尚未被任何策略组使用，节点不会出现在代理节点页",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.dsCaption)
                        .foregroundColor(DS.Palette.warn)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(ProviderUsage.summary(count: refs) + "，节点会自动进入这些组")
                        .font(.dsCaption)
                        .foregroundColor(.secondary)
                }
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

    private func beginEdit(_ name: String) {
        editName = name
        fName = name
        fURL = M.engine.proxyProviders().first { $0.name == name }?.url ?? ""
        showSheet = true
    }

    /// Add or rename/update a provider, then persist via the safe (validate+revert) path.
    private func save() async {
        let name = fName.trimmingCharacters(in: .whitespaces)
        let url = fURL.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, url.hasPrefix("http") else { return }

        var list = M.engine.proxyProviders()
        if let old = editName, let i = list.firstIndex(where: { $0.name == old }) {
            list[i] = (name: name, url: url)
        } else if let i = list.firstIndex(where: { $0.name == name }) {
            list[i] = (name: name, url: url)   // upsert by name
        } else {
            list.append((name: name, url: url))
        }
        showSheet = false
        // 失败时磁盘已回滚，页面也必须回到磁盘真值：否则 UI 停在「已删掉」
        // 的中间态，下一次操作基于错误清单继续，会反复弹同一条回滚提示。
        _ = await M.saveProxyProviders(list)
        await reload()
        // 节点订阅（`.txt` + base64 的 `vless://` / `hysteria2://` 列表）不是 mihomo
        // provider 格式：内核拉下来得到 0 个节点，页面却显示「添加成功」，策略组随
        // 之全空。这里只提示下一步（不替用户换配置——那会把整套策略组和规则一起
        // 换掉），转换动作是卡片上的「转为本地订阅」。
        if editName == nil, await fetchIfNodeSubscription(url) != nil {
            M.showToast("这是节点订阅（base64），点它右侧的「转为本地订阅」才有节点", kind: .warn)
        }
    }

    /// 取回订阅内容；只有确认是「分享链接列表」时才返回（其余情况返回 nil，
    /// 走原来的 proxy-provider 路径）。网络失败也返回 nil——不能因为一次探测
    /// 失败就拒绝用户添加一个合法的 provider。
    private func fetchIfNodeSubscription(_ url: String) async -> String? {
        guard let u = URL(string: url) else { return nil }
        guard let (data, resp) = try? await URLSession.shared.data(from: u),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return NodeSubscription.detect(text) == .shareLinks ? text : nil
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
        usageCounts = M.providerUsageCounts()
        defer { loaded = true }
        guard let p = try? await M.api.fetchProviders() else {
            providers = []
            return
        }
        providers = p.providers.values.filter { $0.vehicleType == "HTTP" }.sorted { $0.name < $1.name }
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
        for p in providers { await update(p.name) }
    }
    private func dateStr(_ unix: Int64) -> String {
        let d = Date(timeIntervalSince1970: TimeInterval(unix))
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: d)
    }
}
