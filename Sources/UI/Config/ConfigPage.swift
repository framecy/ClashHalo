import SwiftUI

// MARK: - Config (dual-mode editor: YAML source + structured form)

struct ConfigPage: View {
    @EnvironmentObject var M: AppModel
    @State private var editingID: String? = nil
    @State private var showImportRemote = false
    @State private var showAddLocal = false

    var body: some View {
        VStack(spacing: 0) {
            PageHead(title: "配置", desc: "本地 YAML 配置 · 远程订阅导入 · 一键切换并热重载") {
                Button { showImportRemote = true } label: { Label("导入订阅", systemImage: "icloud.and.arrow.down") }
                    .controlSize(.small)
                Button { showAddLocal = true } label: { Label("添加本地", systemImage: "doc.badge.plus") }
                    .controlSize(.small).tint(M.accent).buttonStyle(.borderedProminent)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.l) {
                    if M.store.profiles.isEmpty {
                        ContentUnavailable("暂无配置，点击右上角“+”导入", "doc.text")
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: DS.Spacing.l)], spacing: DS.Spacing.l) {
                        ForEach(M.store.profiles) { p in profileCard(p) }
                    }
                }
                .padding(.horizontal, DS.Spacing.xl).padding(.bottom, DS.Spacing.xxl)
            }
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
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: p.source == "remote" ? "icloud.fill" : "doc.fill")
                    .font(.dsLabel)
                    .foregroundColor(active ? M.accent : .secondary)
                Text(p.name).font(.dsLabelBold).lineLimit(1)
                Spacer()
                if active {
                    Text("生效中").font(.dsBodyBold).foregroundColor(M.accent)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(M.accent.opacity(0.12)))
                } else {
                    Circle().stroke(Color.secondary.opacity(0.3), lineWidth: 1.5).frame(width: 12, height: 12)
                }
            }
            Text(p.source == "remote" ? "远程订阅" : "本地文件").font(.dsBody).foregroundColor(.secondary)
            
            Divider().opacity(0.4).padding(.vertical, 2)
            
            HStack {
                Text(relTime(p.updatedAt)).font(.dsBody).foregroundColor(.secondary)
                Spacer()
                if active {
                    Image(systemName: "checkmark.circle.fill").foregroundColor(M.accent).font(.dsLabel)
                } else {
                    Button("设为活动") { M.activateProfile(p.id) }
                        .buttonStyle(.plain).font(.dsBodySemibold).foregroundColor(.accentColor)
                }
            }
        }
        .padding(DS.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.Radius.card).fill(DS.Palette.cardBg))
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.card).stroke(active ? M.accent.opacity(0.4) : DS.Palette.cardBgAlt, lineWidth: active ? 1.5 : 1))
        .contentShape(Rectangle())
        .onTapGesture { if !active { M.activateProfile(p.id) } }
        .contextMenu {
            if !active { Button { M.activateProfile(p.id) } label: { Label("设为活动", systemImage: "checkmark") } }
            Button { editingID = p.id } label: { Label("编辑 YAML…", systemImage: "pencil") }
            if p.source == "remote" {
                Button { Task { _ = await M.store.updateRemote(p.id); if active { M.activateProfile(p.id) }; M.showToast("已更新订阅") } } label: { Label("更新订阅", systemImage: "arrow.clockwise") }
            }
            Divider()
            Button(role: .destructive) { M.store.remove(p.id) } label: { Label("删除", systemImage: "trash") }
                .disabled(active)
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

struct ImportRemoteSheet: View {
    @EnvironmentObject var M: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var name = ""; @State private var url = ""; @State private var busy = false; @State private var err = ""
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.l) {
            Text("导入远程配置或订阅").font(.dsCardLabel)
            TextField("名称", text: $name).textFieldStyle(.roundedBorder)
            TextField("https://…/clash 或订阅链接", text: $url).textFieldStyle(.roundedBorder).font(.dsMono)
            if !err.isEmpty { Text(err).font(.dsBody).foregroundColor(.red) }
            HStack {
                Button("取消") { dismiss() }
                Spacer()
                Button { Task { await go() } } label: { if busy { ProgressView().controlSize(.small) } else { Text("导入") } }
                    .buttonStyle(.borderedProminent).disabled(url.isEmpty || busy)
            }
        }.padding(DS.Spacing.xl).frame(width: 440)
    }
    private func go() async {
        busy = true; err = ""
        let nm = name.isEmpty ? (URL(string: url)?.host ?? "远程配置") : name
        if let id = await M.store.importRemote(name: nm, url: url) { M.activateProfile(id); dismiss() }
        else { err = "下载或解析失败，请检查链接" }
        busy = false
    }
}

struct AddLocalSheet: View {
    @EnvironmentObject var M: AppModel
    @Environment(\.dismiss) var dismiss
    @State private var name = ""
    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.l) {
            Text("添加本地配置").font(.dsCardLabel)
            TextField("名称", text: $name).textFieldStyle(.roundedBorder)
            HStack {
                Button("从文件导入…") { pickFile() }
                Spacer()
                Button("取消") { dismiss() }
            }
        }.padding(DS.Spacing.xl).frame(width: 400)
    }
    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.yaml, .plainText]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url,
           url.startAccessingSecurityScopedResource(),
           let content = try? String(contentsOf: url, encoding: .utf8) {
            defer { url.stopAccessingSecurityScopedResource() }
            let nm = name.isEmpty ? url.deletingPathExtension().lastPathComponent : name
            let id = M.store.addLocal(name: nm, content: content)
            M.activateProfile(id); dismiss()
        }
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
                Button("取消") { dismiss() }
                Button("保存并应用") {
                    M.store.saveContent(profileID, text)
                    if M.store.activeID == profileID { M.activateProfile(profileID) }
                    dismiss()
                }.buttonStyle(.borderedProminent)
            }.padding(14)
            Divider()
            YAMLEditor(text: $text, onChange: {})
        }
        .frame(width: 680, height: 560)
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

