import SwiftUI

// MARK: - Rules (read-only view of the kernel's active rule set)
//
// Rules come from the dedicated /rules endpoint (mihomo does NOT include rules
// in /configs, nor accept rule edits via /configs PATCH). Editing is done by
// modifying the profile YAML on the Config page + hot reload.

struct RulesPage: View {
    @EnvironmentObject var M: AppModel
    @State private var q = ""

    private func matches(_ r: RuleEntry) -> Bool {
        q.isEmpty || "\(r.type)\(r.payload)\(r.proxy)".localizedCaseInsensitiveContains(q)
    }

    var body: some View {
        let rows = M.rules.filter(matches)
        VStack(spacing: 0) {
            PageHead(title: "分流规则", desc: "\(M.rules.count) 条 · 来自运行中内核") {
                Button { Task { await M.refreshRules() } } label: { Label("刷新", systemImage: "arrow.clockwise") }
                    .controlSize(.small)
            }

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("搜索规则类型 / 内容 / 策略", text: $q).textFieldStyle(.plain)
                Spacer()
                Text("\(rows.count) 匹配").font(.dsBody).foregroundColor(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.3))
            Divider()

            if M.rules.isEmpty {
                ContentUnavailable(M.reachable ? "正在加载规则…" : "未连接内核", "line.3.horizontal.decrease")
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, r in row(r) }
                    }
                }
                Text("规则为内核当前生效集合（含 rule-providers 展开）。如需增删改，请在「配置编辑」修改 YAML 后热重载。")
                    .font(.dsBody).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Color(nsColor: .windowBackgroundColor).opacity(0.3))
            }
        }
        .task { await M.refreshRules() }
    }

    private func row(_ r: RuleEntry) -> some View {
        Group {
            HStack(spacing: 10) {
                Text(r.type).font(.dsBodyMedium)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(DS.Palette.hairline))
                    .frame(width: 150, alignment: .leading)
                Text(r.payload.isEmpty ? "—" : r.payload).font(.dsMono).lineLimit(1)
                Spacer()
                Text(r.proxy).font(.dsBody).foregroundColor(M.accent)
            }
            .padding(.horizontal, 14).padding(.vertical, 6)
            .contentShape(Rectangle())
            .contextMenu {
                Button { copyPB(r.payload) } label: { Label("复制内容", systemImage: "doc.on.doc") }
                Button { copyPB("\(r.type),\(r.payload),\(r.proxy)") } label: { Label("复制规则", systemImage: "doc.on.clipboard") }
            }
            Divider().opacity(0.35)
        }
    }

    private func copyPB(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        M.showToast("已复制")
    }
}
