import SwiftUI

// MARK: - Subscriptions (proxy providers)

struct SubscriptionsPage: View {
    @EnvironmentObject var M: AppModel
    @State private var providers: [ProviderEntry] = []
    @State private var busy: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            PageHead(title: "订阅", desc: "\(providers.count) 个 proxy-providers · 节点来源") {
                Button { Task { await updateAll() } } label: { Label("全部更新", systemImage: "arrow.clockwise") }
                    .controlSize(.small)
            }
            ScrollView {
                VStack(spacing: DS.Spacing.m) {
                    if providers.isEmpty {
                        ContentUnavailable("无 HTTP 订阅 (proxy-providers)", "icloud")
                            .frame(maxHeight: .infinity)
                    }
                    ForEach(providers, id: \.name) { p in card(p) }
                }
                .padding(DS.Spacing.xl)
            }
        }
        .task { await reload() }
    }

    private func card(_ p: ProviderEntry) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "icloud.fill").foregroundColor(M.accent)
                    Text(p.name).font(.dsBody).fontWeight(.semibold)
                    Text("\(p.proxies?.count ?? 0) 节点").font(.dsBody)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(DS.Palette.hairline))
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
                            Text("\(fmtBytes(Double(used))) / \(fmtBytes(Double(total)))").font(.dsMono).foregroundColor(.secondary)
                            Spacer()
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

