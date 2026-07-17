import SwiftUI

// MARK: - Subscriptions (proxy providers)

struct SubscriptionsPage: View {
    @EnvironmentObject var M: AppModel
    @State private var providers: [ProviderEntry] = []
    @State private var busy: Set<String> = []
    @State private var showSheet = false
    @State private var editName: String? = nil   // nil = add
    @State private var fName = ""
    @State private var fURL = ""
    @State private var confirmDelete: String? = nil

    var body: some View {
        VStack(spacing: 0) {
            PageToolbar {
                Button { Task { await updateAll() } } label: { Label("全部更新", systemImage: "arrow.clockwise") }
                    .dsButton()
                Button { editName = nil; fName = ""; fURL = ""; showSheet = true } label: { Label("添加订阅", systemImage: "plus") }
                    .dsButton(.prominent)
            }
            if providers.isEmpty {
                ContentUnavailable("无 HTTP 订阅 · 点右上角「添加订阅」", "icloud")
            } else {
                ScrollView {
                    VStack(spacing: DS.Spacing.m) {
                        ForEach(providers, id: \.name) { p in card(p) }
                    }
                    .padding(.horizontal, DS.Layout.pageContentInset)
                    .padding(.top, DS.Spacing.l)
                    .padding(.bottom, DS.Spacing.xxl)
                }
            }
        }
        .task { await reload() }
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
                Text("订阅链接").font(.dsBody).foregroundColor(.secondary)
                TextField("https://…", text: $fURL)
                    .inputStyle()
                    .font(.dsMono)
            }
            HStack {
                Button("取消") { showSheet = false }
                    .dsButton()

                Spacer()
                Button("保存") { Task { await save() } }
                    .dsButton(.prominent)
                    .disabled(fName.trimmingCharacters(in: .whitespaces).isEmpty || !fURL.hasPrefix("http"))
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
                    Spacer(minLength: 0)
                    if busy.contains(p.name) {
                        ProgressView().controlSize(.small)
                    } else {
                        Button { Task { await update(p.name) } } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.borderless).help("更新")
                        Button { beginEdit(p.name) } label: { Image(systemName: "pencil") }
                            .buttonStyle(.borderless).help("编辑")
                        Button { confirmDelete = p.name } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).foregroundColor(DS.Palette.error).help("删除")
                    }
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
        if await M.saveProxyProviders(list) { await reload() }
    }

    private func delete(_ name: String) async {
        var list = M.engine.proxyProviders()
        list.removeAll { $0.name == name }
        if await M.saveProxyProviders(list) { await reload() }
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

