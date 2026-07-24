import SwiftUI

// MARK: - Config (dual-mode editor: YAML source + structured form)

struct ConfigPage: View {
    @EnvironmentObject var M: AppModel
    @State private var editingID: String? = nil
    @State private var showImportRemote = false
    @State private var showAddLocal = false
    @State private var showWipeConfirm = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.m) {
                PageHead(title: "配置编辑") {
                    Button { showWipeConfirm = true } label: { Label("清空全部", systemImage: "trash") }
                        .dsButton(.destructive)
                        .disabled(M.store.profiles.isEmpty || M.engine.isBusy)
                    Button { showImportRemote = true } label: { Label("导入订阅", systemImage: "icloud.and.arrow.down") }
                        .dsButton()
                    Button { showAddLocal = true } label: { Label("本地导入", systemImage: "doc.badge.plus") }
                        .dsButton(.prominent)
                }
                .padding(.horizontal, -DS.Layout.pageContentInset)

                if M.store.profiles.isEmpty {
                    ContentUnavailable("暂无配置，点击右上角「导入订阅」或「本地导入」", "doc.text")
                        .frame(minHeight: 320)
                } else {
                    DSSection(title: "配置文件 · 多配置选择",
                              count: "\(M.store.profiles.count) 个配置") {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: DS.Layout.gridMinProfile),
                                               spacing: DS.Layout.gridGutter)],
                            spacing: DS.Layout.gridGutter
                        ) {
                            ForEach(M.store.profiles) { p in profileCard(p) }
                        }
                    }
                }
            }
            .padding(.horizontal, DS.Layout.pageContentInset)
            .padding(.bottom, 26)
        }
        .confirmationDialog("清空全部 \(M.store.profiles.count) 个配置？",
                            isPresented: $showWipeConfirm, titleVisibility: .visible) {
            Button("清空全部", role: .destructive) { M.deleteAllProfiles() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("将删除所有配置文件、订阅链接与当前生效的 config.yaml，"
                 + "并自动关闭系统代理与 TUN、停止内核。此操作不可撤销；"
                 + "重新导入配置后需手动开启系统代理 / TUN。")
        }
        .sheet(isPresented: $showImportRemote) { ImportRemoteSheet() }
        .sheet(isPresented: $showAddLocal) { AddLocalSheet() }
        .sheet(item: Binding(get: { editingID.map { IDBox(id: $0) } }, set: { editingID = $0?.id })) { box in
            ProfileEditSheet(profileID: box.id)
        }
    }

    struct IDBox: Identifiable { let id: String }

    private func profileCard(_ p: Profile) -> some View {
        let active = M.store.activeID == p.id
        let pendingApply = M.pendingApplyID == p.id
        // Drafts are visually distinct from inactive-but-already-applied
        // profiles: amber outline + a small badge instead of the empty
        // circle + "设为活动" CTA used by inactive applied ones.
        let draft = p.needsApply && !active
        let stroke: Color = active ? DS.Palette.accent
            : draft ? DS.Palette.warn.opacity(0.6)
            : DS.Palette.border
        let strokeWidth: CGFloat = (active || draft) ? 1 : 0.5

        // 原型 `.prof-card`：图标槽 + 名称/徽章 + 来源元信息 + 路径 mono + 底部动作行
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                DSIconSlot(systemImage: p.source == "remote" ? "icloud" : "doc.text",
                           size: 30,
                           tint: active ? DS.Palette.accent : Color.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(p.name).font(.dsCardLabel).lineLimit(1)
                        if draft { DSStatusBadge(text: "待应用", tint: DS.Palette.warn) }
                        Spacer(minLength: DS.Spacing.xs)
                        if active {
                            DSStatusBadge(text: "生效中")
                        } else if pendingApply {
                            ProgressView().controlSize(.small)
                        } else {
                            Circle()
                                .strokeBorder(DS.Palette.borderStrong, lineWidth: 1.5)
                                .frame(width: 15, height: 15)
                        }
                    }
                    HStack(spacing: 5) {
                        Text(p.source == "remote" ? "远程" : "本地")
                            .font(.dsCaptionBold)
                            .foregroundColor(active ? DS.Palette.accent : .secondary)
                        Text("· 更新 \(relTime(p.updatedAt))")
                            .font(.dsCaption).foregroundColor(.secondary)
                    }
                }
            }

            Text(p.url ?? "本地文件")
                .font(.dsMonoTiny)
                .foregroundColor(DS.Palette.textFaint)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.top, DS.Spacing.s)

            Spacer(minLength: DS.Spacing.s)

            // 底部动作行 — 高度锁定，使生效/未生效卡尺寸一致
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                if active {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(DS.Palette.accent)
                        .font(.dsLabel)
                } else if draft {
                    Button { M.selectForApply(p.id) } label: { Text("应用此配置") }
                        .dsButton(.warning)
                } else {
                    Button("设为生效") { M.selectForApply(p.id) }
                        .dsButton()
                }
                if p.source == "remote" {
                    DSIconButton(systemImage: "arrow.clockwise", help: "更新订阅") {
                        Task {
                            let ok = await M.store.updateRemote(p.id)
                            if ok {
                                if active { M.selectForApply(p.id) }
                                M.showToast("订阅「\(p.name)」已更新成功", kind: .ok)
                            } else {
                                M.showToast("订阅「\(p.name)」更新失败，已保留原配置", kind: .error)
                            }
                        }
                    }
                }
                DSIconButton(systemImage: "xmark", help: "删除") { M.store.remove(p.id) }
                    .disabled(active || draft)
                    .opacity(active || draft ? 0.4 : 1)
            }
            .frame(height: DS.Layout.controlHeight, alignment: .center)
            .padding(.top, 10)
        }
        .padding(.horizontal, DS.Spacing.m)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, minHeight: DS.Layout.profileCardMinHeight, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .fill(active ? DS.Palette.accentSoft : DS.Palette.windowBg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                .strokeBorder(stroke, lineWidth: strokeWidth)
        )
        .contentShape(Rectangle())
        .onTapGesture { if !active && !pendingApply { M.selectForApply(p.id) } }
        .contextMenu {
            if !active { Button { M.selectForApply(p.id) } label: { Label("设为活动", systemImage: "checkmark") } }
            Button { editingID = p.id } label: { Label("编辑 YAML…", systemImage: "pencil") }
            if draft {
                Button(role: .destructive) { M.store.discardDraft(p.id) } label: { Label("放弃导入", systemImage: "trash.slash") }
            }
            if p.source == "remote" {
                Button {
                    Task {
                        let ok = await M.store.updateRemote(p.id)
                        if ok {
                            if active { M.selectForApply(p.id) }
                            M.showToast("订阅「\(p.name)」已更新成功", kind: .ok)
                        } else {
                            M.showToast("订阅「\(p.name)」更新失败，已保留原配置", kind: .error)
                        }
                    }
                } label: {
                    Label("更新订阅", systemImage: "arrow.clockwise")
                }
            }
            Divider()
            Button(role: .destructive) { M.store.remove(p.id) } label: { Label("删除", systemImage: "trash") }
                .disabled(active || draft)
        }
    }

    private func relTime(_ d: Date) -> String {
        let s = Int(Date().timeIntervalSince(d))
        if s < 60 { return "刚刚" }
        if s < 3600 { return "\(s/60) 分钟前" }
        if s < 86400 { return "\(s/3600) 小时前" }
        return "\(s/86400) 天前"
    }
}

// MARK: - Import / edit sheets

// MARK: - Two-stage import sheets (Phase 1: import isolation)
//
// Both sheets share the same lifecycle: `.pick` → `.preview`. The preview
// stage is reached **without touching the kernel**: the YAML is downloaded
// (remote) or read from disk (local), then a lightweight row-scan summary
// is shown. The user then chooses:
//   - 放弃 / 取消        : in-memory draft is dropped, nothing on disk
//   - 添加到配置列表      : profile lands on disk as `isApplied = false` (a
//                          draft, visible in the card list with a 「待应用」
//                          badge until the user taps it)
//   - 导入并应用          : draft lands on disk and is immediately pushed to
//                          the running kernel via `selectForApply`

struct ImportRemoteSheet: View {
    @EnvironmentObject var M: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var name = ""
    @State private var url = ""
    @State private var busy = false
    @State private var err = ""
    @State private var stage: Stage = .pick
    @State private var previewContent = ""
    @State private var preview = YAMLPreview()
    enum Stage { case pick, preview }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.l) {
            if stage == .pick {
                Text("导入远程配置或订阅").font(.dsCardLabel)
                TextField("名称", text: $name).inputStyle()
                TextField("https://…/clash 或订阅链接", text: $url).inputStyle().font(.dsMono)
                if !err.isEmpty { Text(err).font(.dsBody).foregroundColor(DS.Palette.error) }
                HStack {
                    Button("取消") { dismiss() }.dsButton()
                    Spacer()
                    Button { Task { await fetchPreview() } } label: {
                        if busy { ProgressView().controlSize(.small) } else { Text("下载预览") }
                    }
                    .dsButton(.prominent).disabled(url.isEmpty || busy)
                }

            } else {
                Text("导入预览").font(.dsCardLabel)
                previewSummary
                if !err.isEmpty { Text(err).font(.dsBody).foregroundColor(DS.Palette.error) }
                HStack {
                    Button("放弃") { stage = .pick }.dsButton()
                    Spacer()
                    Button("添加到配置列表") { Task { await saveOnly() } }.dsButton()
                    Button("导入并应用") { Task { await saveAndApply() } }
                        .dsButton(.prominent).disabled(name.isEmpty || busy)
                }

            }
        }.padding(DS.Spacing.xl).frame(minWidth: 440, idealWidth: 480, maxWidth: 600)
    }

    private var previewSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("检测到 \(preview.nodeCount) 个节点、\(preview.groupCount) 个分组、\(preview.ruleCount) 条规则")
                .font(.dsBody).foregroundColor(.secondary)
            Text("文件大小：\(preview.bytes) 字节")
                .font(.dsBody).foregroundColor(.secondary)
            if preview.hasProxyProviders {
                Label("包含 proxy-providers，将在线拉取节点", systemImage: "icloud.and.arrow.down")
                    .font(.dsBody).foregroundColor(.secondary)
            }
        }
    }

    private func fetchPreview() async {
        busy = true; err = ""
        guard let u = URL(string: url) else { err = "链接无效"; busy = false; return }
        do {
            let (data, _) = try await URLSession.shared.data(from: u)
            guard let text = String(data: data, encoding: .utf8), text.contains(":") else {
                err = "下载失败或内容不是 YAML"; busy = false; return
            }
            previewContent = text
            preview = M.store.previewOfContent(text)
            if name.isEmpty { name = u.host ?? "远程配置" }
            stage = .preview
        } catch {
            err = "下载失败：\(error.localizedDescription)"
        }
        busy = false
    }

    private func saveOnly() async {
        guard !previewContent.isEmpty else { dismiss(); return }
        let nameToUse = name.isEmpty ? (URL(string: url)?.host ?? "远程配置") : name
        if url.lowercased().hasPrefix("http://") || url.lowercased().hasPrefix("https://") {
            _ = M.store.importRemoteDraft(name: nameToUse, url: url, content: previewContent)
        } else {
            _ = M.store.importLocalDraft(name: nameToUse, content: previewContent)
        }
        dismiss()
    }

    private func saveAndApply() async {
        guard !previewContent.isEmpty else { dismiss(); return }
        let nameToUse = name.isEmpty ? (URL(string: url)?.host ?? "远程配置") : name
        let id: String
        if url.lowercased().hasPrefix("http://") || url.lowercased().hasPrefix("https://") {
            id = M.store.importRemoteDraft(name: nameToUse, url: url, content: previewContent)
        } else {
            id = M.store.importLocalDraft(name: nameToUse, content: previewContent)
        }
        M.selectForApply(id)
        dismiss()
    }
}

struct AddLocalSheet: View {
    @EnvironmentObject var M: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var name = ""
    @State private var stage: Stage = .pick
    @State private var draftContent = ""
    @State private var preview = YAMLPreview()
    enum Stage { case pick, preview }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.l) {
            if stage == .pick {
                Text("添加本地配置").font(.dsCardLabel)
                TextField("名称", text: $name).inputStyle()
                HStack {
                    Button("从文件导入…") { pickFile() }.dsButton()
                    Spacer()
                    Button("取消") { dismiss() }.dsButton()
                }

            } else {
                Text("导入预览").font(.dsCardLabel)
                Text("检测到 \(preview.nodeCount) 个节点、\(preview.groupCount) 个分组、\(preview.ruleCount) 条规则")
                    .font(.dsBody).foregroundColor(.secondary)
                Text("文件大小：\(preview.bytes) 字节")
                    .font(.dsBody).foregroundColor(.secondary)
                if preview.hasProxyProviders {
                    Label("包含 proxy-providers，将在线拉取节点", systemImage: "icloud.and.arrow.down")
                        .font(.dsBody).foregroundColor(.secondary)
                }
                HStack {
                    Button("放弃") { stage = .pick }.dsButton()
                    Spacer()
                    Button("添加到配置列表") { Task { await saveDraft(apply: false) } }.dsButton()
                        .disabled(name.isEmpty)
                    Button("导入并应用") { Task { await saveDraft(apply: true) } }
                        .dsButton(.prominent).disabled(name.isEmpty)
                }

            }
        }.padding(DS.Spacing.xl).frame(minWidth: 400, idealWidth: 440, maxWidth: 560)
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.yaml, .plainText]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url,
           url.startAccessingSecurityScopedResource(),
           let content = try? String(contentsOf: url, encoding: .utf8) {
            defer { url.stopAccessingSecurityScopedResource() }
            draftContent = content
            preview = M.store.previewOfContent(content)
            if name.isEmpty { name = url.deletingPathExtension().lastPathComponent }
            stage = .preview
        }
    }

    private func saveDraft(apply: Bool) async {
        let id = M.store.importLocalDraft(name: name.isEmpty ? "未命名配置" : name,
                                          content: draftContent)
        if apply { M.selectForApply(id) }
        dismiss()
    }
}

struct ProfileEditSheet: View {
    @EnvironmentObject var M: AppModel
    @Environment(\.dismiss) var dismiss
    let profileID: String
    @State private var text = ""
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("编辑配置").font(.dsCardLabel)
                Spacer()
                Button("取消") { dismiss() }.dsButton()
                Button("保存并应用") {
                    M.store.saveContent(profileID, text)
                    if M.store.activeID == profileID { M.activateProfile(profileID) }
                    dismiss()
                }.dsButton(.prominent)
            }

            .padding(DS.Spacing.m)
            Divider()
            YAMLEditor(text: $text, onChange: {})
        }
        .frame(minWidth: 680, idealWidth: 720, maxWidth: 900, minHeight: 560, idealHeight: 620, maxHeight: 800)
        .onAppear { text = M.store.content(profileID) }
    }
}

// MARK: - Structured form (editable common fields)

private struct FormEditor: View {
    let configs: [String: Any]
    let accent: Color
    var body: some View {
        ScrollView {
            VStack(spacing: DS.Spacing.l) {
                Card(title: "入站端口") {
                    VStack(spacing: 9) {
                        kv("混合端口", str(configs["mixed-port"]))
                        kv("SOCKS 端口", str(configs["socks-port"]))
                        kv("运行模式", str(configs["mode"]))
                        kv("日志级别", str(configs["log-level"]))
                    }
                }
                Card(title: "TUN") {
                    let tun = configs["tun"] as? [String: Any] ?? [:]
                    VStack(spacing: 9) {
                        kv("启用", bool(tun["enable"]))
                        kv("协议栈", str(tun["stack"]))
                        kv("自动路由", bool(tun["auto-route"]))
                    }
                }
                Card(title: "DNS") {
                    let dns = configs["dns"] as? [String: Any] ?? [:]
                    VStack(spacing: 9) {
                        kv("启用", bool(dns["enable"]))
                        kv("增强模式", str(dns["enhanced-mode"]))
                        kv("Fake-IP 段", str(dns["fake-ip-range"]))
                    }
                }
                Text("结构化表单为只读概览；如需修改请用 YAML 源码模式编辑后「应用并热重载」。")
                    .font(.dsBody).foregroundColor(.secondary)
                Spacer(minLength: 0)
            }.padding(DS.Spacing.xl)
        }
    }
    private func kv(_ l: String, _ v: String) -> some View {
        HStack { Text(l).font(.dsBody).foregroundColor(.secondary); Spacer(); Text(v).font(.dsMono) }
    }
    private func str(_ v: Any?) -> String { v.map { "\($0)" } ?? "—" }
    private func bool(_ v: Any?) -> String { (v as? Bool) == true ? "是" : "否" }
}

// MARK: - YAML syntax-highlighting editor (NSTextView)

struct YAMLEditor: NSViewRepresentable {
    @Binding var text: String
    var onChange: () -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        guard let tv = scroll.documentView as? NSTextView else { return scroll }
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.allowsUndo = true
        tv.backgroundColor = .textBackgroundColor
        tv.textContainerInset = NSSize(width: 8, height: 8)
        context.coordinator.textView = tv
        tv.string = text
        context.coordinator.highlight()
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let tv = context.coordinator.textView else { return }
        if tv.string != text {
            tv.string = text
            context.coordinator.highlight()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let parent: YAMLEditor
        weak var textView: NSTextView?
        private var highlightTimer: Timer?
        init(_ p: YAMLEditor) { parent = p }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            parent.text = tv.string
            parent.onChange()
            scheduleHighlight()
        }

        /// Debounce highlight: wait 150ms of idle after the last keystroke
        /// before running the full regex pass. Prevents stutter on large files.
        private func scheduleHighlight() {
            highlightTimer?.invalidate()
            highlightTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: false) { [weak self] _ in
                self?.highlight()
            }
        }

        // Lightweight line-based YAML highlighter.
        func highlight() {
            guard let tv = textView, let storage = tv.textStorage else { return }
            let full = tv.string as NSString
            let sel = tv.selectedRange()
            storage.beginEditing()
            storage.addAttribute(.foregroundColor, value: NSColor.textColor, range: NSRange(location: 0, length: full.length))
            storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), range: NSRange(location: 0, length: full.length))
            apply(#"#[^\n]*"#, .systemGray, full, storage)                       // comments
            apply(#"^\s*[-]?\s*[\w.\-]+(?=\s*:)"#, .systemTeal, full, storage)    // keys
            apply(#":\s*[\"'][^\"'\n]*[\"']"#, .systemGreen, full, storage)       // quoted values
            apply(#":\s*-?\d+(\.\d+)?\b"#, .systemOrange, full, storage)          // numbers
            apply(#"\b(true|false|null)\b"#, .systemPurple, full, storage)        // literals
            storage.endEditing()
            tv.setSelectedRange(sel)
        }
        private func apply(_ pattern: String, _ color: NSColor, _ s: NSString, _ storage: NSTextStorage) {
            guard let re = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return }
            re.enumerateMatches(in: s as String, range: NSRange(location: 0, length: s.length)) { m, _, _ in
                if let r = m?.range { storage.addAttribute(.foregroundColor, value: color, range: r) }
            }
        }
    }
}

