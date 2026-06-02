import SwiftUI

// MARK: - Rules

struct RulesPage: View {
    @EnvironmentObject var M: AppModel
    @State private var q = ""
    @State private var editing: (idx: Int, text: String)? = nil
    @State private var showAdd = false
    @State private var newRule = ""

    private func matches(_ s: String) -> Bool { q.isEmpty || s.localizedCaseInsensitiveContains(q) }

    var body: some View {
        let enabled = M.inlineRules
        let disabled = M.disabledRules
        VStack(spacing: 0) {
            PageHead(title: "分流规则", desc: "\(enabled.count) 启用 · \(disabled.count) 禁用") {
                Button { newRule = ""; showAdd = true } label: { Label("添加规则", systemImage: "plus") }
                    .controlSize(.small).tint(M.accent).buttonStyle(.borderedProminent)
            }

            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundColor(.secondary)
                TextField("搜索规则内容或策略", text: $q).textFieldStyle(.plain)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.3))
            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(enabled.indices), id: \.self) { idx in
                        let rule = enabled[idx]
                        if matches(rule) { row(rule, idx: idx, disabled: false, count: enabled.count) }
                    }
                    if !disabled.isEmpty {
                        HStack { Text("已禁用").font(.caption).fontWeight(.bold).foregroundColor(.secondary); Spacer() }
                            .padding(.horizontal, 14).padding(.top, 16).padding(.bottom, 8)
                        ForEach(Array(disabled.indices), id: \.self) { idx in
                            let rule = disabled[idx]
                            if matches(rule) { row(rule, idx: -1, disabled: true, count: 0) }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            RuleEditSheet(title: "编辑规则", initial: editing?.text ?? "") { newText in
                guard let e = editing else { return }
                var r = M.inlineRules; if e.idx >= 0 && e.idx < r.count { r[e.idx] = newText }
                Task { await M.applyRules(r) }; editing = nil
            } onCancel: { editing = nil }
        }
        .sheet(isPresented: $showAdd) {
            RuleEditSheet(title: "添加规则", initial: "") { t in
                Task { await M.applyRules(M.inlineRules + [t]) }; showAdd = false
            } onCancel: { showAdd = false }
        }
    }

    private func row(_ rule: String, idx: Int, disabled: Bool, count: Int) -> some View {
        let parts = rule.split(separator: ",", maxSplits: 2).map { $0.trimmingCharacters(in: .whitespaces) }
        let type = parts.first ?? rule
        let payload = parts.count > 1 ? parts[1] : ""
        let proxy = parts.count > 2 ? parts[2] : (parts.count > 1 && type == "MATCH" ? parts[1] : "")
        return Group {
            HStack(spacing: 10) {
                Text(type).font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.primary.opacity(0.08)))
                    .frame(width: 140, alignment: .leading)
                Text(payload.isEmpty ? "—" : payload).font(.caption.monospaced()).lineLimit(1)
                    .strikethrough(disabled)
                Spacer()
                Text(proxy).font(.caption).foregroundColor(disabled ? .secondary : M.accent)
            }
            .padding(.horizontal, 14).padding(.vertical, 6)
            .opacity(disabled ? 0.5 : 1)
            .contentShape(Rectangle())
            .contextMenu {
                if disabled {
                    Button { Task { await M.enableRule(rule) } } label: { Label("启用规则", systemImage: "checkmark.circle") }
                } else {
                    Button { Task { await M.disableRule(rule) } } label: { Label("禁用规则", systemImage: "xmark.circle") }
                    Button { editing = (idx, rule) } label: { Label("编辑规则…", systemImage: "pencil") }
                    Divider()
                    Button { move(idx, -1) } label: { Label("上移", systemImage: "chevron.up") }.disabled(idx == 0)
                    Button { move(idx, 1) } label: { Label("下移", systemImage: "chevron.down") }.disabled(idx == count - 1)
                    Divider()
                    Button(role: .destructive) { remove(idx) } label: { Label("删除规则", systemImage: "trash") }
                }
                Divider()
                Button { copyPB(payload) } label: { Label("复制内容", systemImage: "doc.on.doc") }
                Button { copyPB(rule) } label: { Label("复制规则", systemImage: "doc.on.clipboard") }
            }
            Divider().opacity(0.35)
        }
    }

    private func move(_ idx: Int, _ dir: Int) {
        var r = M.inlineRules; let j = idx + dir
        guard idx >= 0, j >= 0, idx < r.count, j < r.count else { return }
        r.swapAt(idx, j); Task { await M.applyRules(r) }
    }
    private func remove(_ idx: Int) {
        var r = M.inlineRules; guard idx >= 0, idx < r.count else { return }
        r.remove(at: idx); Task { await M.applyRules(r) }
    }
    private func copyPB(_ s: String) {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(s, forType: .string)
        M.showToast("已复制")
    }
}

