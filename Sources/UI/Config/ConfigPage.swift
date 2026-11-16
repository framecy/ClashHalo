import SwiftUI

// MARK: - Config (dual-mode editor: YAML source + structured form)

struct ConfigPage: View {
    @EnvironmentObject var M: AppModel
    @State private var editingID: String? = nil
    /// 导入弹窗唯一入口：每次展示生成新身份，避免 `ImportRemoteSheet` /
    /// `AddLocalSheet` 的 @State（名称 / URL / stage）沿用上一次打开的残留值。
    @State private var importSheet: ImportSheetTarget? = nil
    @State private var showWipeConfirm = false
    /// UI-10：删单个配置的确认目标（对齐删订阅的 confirmationDialog 范式）。
    @State private var confirmDeleteProfile: Profile? = nil
    /// 运行配置与活动 profile 的差异快照。页面出现时算一次，不进 body。
    @State private var drift: [String] = []

    /// 运行配置已偏离 profile 的提示。
    ///
    /// 这不是装饰：设置页/规则页/DNS 页直接改运行配置，而 profile 只有
    /// 「保存并应用」才写。两者分叉后，用户点一次「切换配置」就会把运行配置里的
    /// 改动（含 TUN 的 mtu 与排除网段、find-process-mode、API secret）整片覆盖。
    @ViewBuilder
    private var driftBanner: some View {
        Card(title: "运行配置已偏离当前配置", icon: "exclamationmark.triangle") {
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                Text("有 \(drift.count) 项与活动配置不同。设置页、规则页、DNS 页的改动直接写在运行配置里，不会回写到配置。")
                    .font(.dsBody).foregroundColor(.secondary)
                DisclosureGroup("查看差异") {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(drift, id: \.self) { line in
                            Text(line).font(.dsMono).foregroundColor(.secondary)
                        }
                    }
                }
                .font(.dsCaption)
                HStack {
                    Spacer()
                    // 两个方向都要给：只给「以配置为准」等于默认运行配置是脏的，
                    // 而实际上设置页的改动常常才是用户想要的那一份。
                    Button("把运行配置存回配置") {
                        if M.saveRunningConfigIntoProfile() { drift = [] }
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(M.engine.isBusy)
                    Button("以配置为准（覆盖运行配置）") {
                        if let id = M.store.profiles.first(where: { $0.id == M.store.activeID })?.id {
                            M.selectForApply(id)
                            drift = []
                        }
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(M.engine.isBusy)
                }
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            PageToolbar {
                Button { showWipeConfirm = true } label: { Label("清空全部", systemImage: "trash") }
                    .dsButton(.destructive)
                    .disabled(M.store.profiles.isEmpty || M.engine.isBusy)
                Button { importSheet = ImportSheetTarget(source: .remote) } label: { Label("导入订阅", systemImage: "icloud.and.arrow.down") }
                    .dsButton()
                Button { importSheet = ImportSheetTarget(source: .local) } label: { Label("添加本地", systemImage: "doc.badge.plus") }
                    .dsButton(.prominent)
            }

            if M.store.profiles.isEmpty {
                // 顶对齐铺满一行；放进 ScrollView 是硬要求：满高容器外再叠
                // padding 会把整个 NavigationSplitView 顶出视口（侧栏和详情
                // 一起上移的严重错位）。卡片已用 fillHeight:false 取内容高度，
                // 不需要 fixedSize。
                ScrollView {
                    GettingStartedCard()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, DS.Layout.pageContentInset)
                        .padding(.top, DS.Spacing.l)
                        .padding(.bottom, DS.Spacing.xxl)
                }
            } else {
                ScrollView {
                    VStack(spacing: DS.Spacing.l) {
                        if !drift.isEmpty { driftBanner }
                        // 接管还没开时，把三步清单压在配置列表上方：导入成功后
                        // 「第 1 步变勾」就在原地可见，接管一开即退场。
                        if GettingStartedCard.shouldShowAboveProfileList(M) {
                            GettingStartedCard()
                        }
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 280), spacing: DS.Spacing.l)],
                            spacing: DS.Spacing.l
                        ) {
                            ForEach(M.store.profiles) { p in profileCard(p) }
                        }
                    }
                    // 顶距与 pageContentInset 节奏一致，避免卡片贴死 chrome 分割线
                    .padding(.horizontal, DS.Layout.pageContentInset)
                    .padding(.top, DS.Spacing.l)
                    .padding(.bottom, DS.Spacing.xxl)
                }
                .task { drift = M.configDriftAgainstActiveProfile() }
            }
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
        // UI-10：删单个配置也要确认（此前右键「删除」直接执行，其余破坏性
        // 操作都有确认弹窗）。活动/草稿配置在菜单里已 disabled，这里只兜非活动。
        .confirmationDialog("删除配置「\(confirmDeleteProfile?.name ?? "")」？",
                            isPresented: Binding(get: { confirmDeleteProfile != nil },
                                                 set: { if !$0 { confirmDeleteProfile = nil } }),
                            titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let p = confirmDeleteProfile { M.store.remove(p.id) }
                confirmDeleteProfile = nil
            }
            Button("取消", role: .cancel) { confirmDeleteProfile = nil }
        } message: {
            Text("将删除该配置文件与其订阅链接，此操作不可撤销。")
        }
        .sheet(item: $importSheet) { target in
            switch target.source {
            case .remote: ImportRemoteSheet()
            case .local:  AddLocalSheet()
            }
        }
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

        return VStack(alignment: .leading, spacing: 0) {
            // Header row — fixed height so badges don't stretch cards unevenly
            HStack(spacing: DS.Spacing.s) {
                Image(systemName: p.source == "remote" ? "icloud.fill" : "doc.fill")
                    .font(.dsLabel)
                    .foregroundColor(active ? DS.Palette.accent : .secondary)
                    .frame(width: DS.Icon.md, alignment: .center)
                Text(p.name)
                    .font(.dsLabelBold)
                    .lineLimit(1)
                if draft {
                    Text("待应用")
                        .font(.dsBodyBold)
                        .foregroundColor(DS.Palette.warn)
                        .padding(.horizontal, DS.Spacing.xs)
                        .padding(.vertical, DS.Spacing.xs / 2)
                        .background(Capsule().fill(DS.Palette.warn.opacity(0.15)))
                }
                Spacer(minLength: 0)
                if active {
                    Text("生效中")
                        .font(.dsBodyBold)
                        .foregroundColor(DS.Palette.accent)
                        .padding(.horizontal, DS.Spacing.xs)
                        .padding(.vertical, DS.Spacing.xs / 2)
                        .background(Capsule().fill(DS.Palette.accent.opacity(0.12)))
                } else if pendingApply {
                    ProgressView().controlSize(.small)
                } else {
                    Circle()
                        .stroke(DS.Palette.track, lineWidth: 1.5)
                        .frame(width: 12, height: 12)
                }
            }
            .frame(height: DS.Layout.controlHeight, alignment: .center)

            Text(p.source == "remote" ? "远程订阅" : "本地文件")
                .font(.dsBody)
                .foregroundColor(.secondary)
                .padding(.top, DS.Spacing.xs)

            Spacer(minLength: DS.Spacing.m)

            Divider().overlay(DS.Palette.separator)

            // Footer row — locked to controlHeight so active checkmark / CTA share size
            HStack(spacing: DS.Spacing.s) {
                Text(relTime(p.updatedAt))
                    .font(.dsBody)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if active {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(DS.Palette.accent)
                        .font(.dsLabel)
                } else if draft {
                    Button { M.selectForApply(p.id) } label: { Text("应用此配置") }
                        .dsButton(.warning)
                } else {
                    Button("设为活动") { M.selectForApply(p.id) }
                        .dsButton()
                }
            }
            .frame(height: DS.Layout.controlHeight, alignment: .center)
            .padding(.top, DS.Spacing.m)
        }
        .padding(DS.Spacing.l)
        .frame(maxWidth: .infinity, minHeight: DS.Layout.profileCardMinHeight, alignment: .topLeading)
        // P3：页面网格上的兄弟卡一律 dsCardChrome（Light 双层阴影 / Dark 抬升色），
        // 不再手写 background+stroke 分叉；活动/草稿的状态环叠在标准 chrome 之上。
        .dsCardChrome()
        .overlay {
            if active || draft {
                RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
                    .stroke(active ? DS.Palette.accent.opacity(0.4) : DS.Palette.warn.opacity(0.5),
                            lineWidth: 1.5)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if !active && !pendingApply { M.selectForApply(p.id) } }
        .contextMenu {
            if !active {
                Button { M.selectForApply(p.id) } label: { Label("设为活动", systemImage: "checkmark") }
                    .disabled(M.engine.isBusy)
            }
            Button { editingID = p.id } label: { Label("编辑 YAML…", systemImage: "pencil") }
                .disabled(M.engine.isBusy)
            if draft {
                Button(role: .destructive) { M.store.discardDraft(p.id) } label: { Label("放弃导入", systemImage: "trash.slash") }
                    .disabled(M.engine.isBusy)
            }
            if p.source == "remote" {
                Button {
                    Task {
                        let ok = await M.store.updateRemote(p.id)
                        if ok {
                            if active { M.selectForApply(p.id) }
                            // P2-2（方案 B）：这里刷的是**磁盘上的配置文件**，不是
                            // 内核里的节点缓存。文案必须说清是哪一件事，否则用户在两个
                            // 页面都能看到“已更新”，却更新的不是一个东西。
                            M.showToast("配置文件「\(p.name)」已从订阅源更新", kind: .ok)
                        } else {
                            M.showToast("配置文件「\(p.name)」更新失败，已保留原文件", kind: .error)
                        }
                    }
                } label: {
                    // 配置页的“更新”= 用订阅源重写磁盘配置文件（节点缓存不刷新，
                    // 那是订阅页的事）。菜单项文案跟着说清。
                    Label("更新配置文件", systemImage: "arrow.clockwise")
                }
                .disabled(M.engine.isBusy)
            }
            Divider()
            Button(role: .destructive) { confirmDeleteProfile = p } label: { Label("删除", systemImage: "trash") }
                .disabled(active || draft || M.engine.isBusy)
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
    /// UI-11：nil = 无错误。错误行固定占位（Text(err ?? " ")），出现/消失
    /// 不改变表单高度、不挤动底部按钮（design.md §6.4）。
    @State private var err: String? = nil
    @State private var stage: Stage = .pick
    @State private var previewContent = ""
    @State private var preview = YAMLPreview()
    /// 非 nil = 这次下载的内容是 base64 分享链接订阅，已自动转成配置。
    /// 订阅源给「N 个节点」而预览是别的数字时，这行是唯一的解释。
    @State private var conversionNote: String? = nil
    enum Stage { case pick, preview }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.l) {
            if stage == .pick {
                Text("导入远程配置或订阅").font(.dsCardLabel)
                TextField("名称", text: $name).inputStyle()
                    .onSubmit { Task { await fetchPreview() } }
                TextField("https://…/clash 或订阅链接", text: $url).inputStyle().font(.dsMono)
                    .onSubmit { Task { await fetchPreview() } }
                Text(err ?? " ")
                    .font(.dsBody)
                    .foregroundColor(err == nil ? .clear : DS.Palette.error)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("取消") { dismiss() }.dsButton()
                    Spacer()
                    Button { Task { await fetchPreview() } } label: {
                        if busy { ProgressView().controlSize(.small) } else { Text("下载预览") }
                    }
                    .dsButton(.prominent).disabled(url.isEmpty || busy)
                    .keyboardShortcut(.defaultAction)
                }

            } else {
                Text("导入预览").font(.dsCardLabel)
                previewSummary
                Text(err ?? " ")
                    .font(.dsBody)
                    .foregroundColor(err == nil ? .clear : DS.Palette.error)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("放弃") { stage = .pick }.dsButton()
                    Spacer()
                    Button("添加到配置列表") { Task { await saveOnly() } }.dsButton()
                    Button("导入并应用") { Task { await saveAndApply() } }
                        .dsButton(.prominent).disabled(name.isEmpty || busy)
                        .keyboardShortcut(.defaultAction)
                }

            }
        }.padding(DS.Spacing.xl).frame(minWidth: 440, idealWidth: 480, maxWidth: 600)
    }

    private var previewSummary: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.s) {
            Text("检测到 \(preview.nodeCount) 个节点、\(preview.groupCount) 个分组、\(preview.ruleCount) 条规则")
                .font(.dsBody).foregroundColor(.secondary)
            Text("文件大小：\(preview.bytes) 字节")
                .font(.dsBody).foregroundColor(.secondary)
            if preview.hasProxyProviders {
                Label("包含 proxy-providers，将在线拉取节点", systemImage: "icloud.and.arrow.down")
                    .font(.dsBody).foregroundColor(.secondary)
            }
            if let conversionNote {
                Label(conversionNote, systemImage: "arrow.triangle.2.circlepath")
                    .font(.dsBody).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func fetchPreview() async {
        busy = true; err = nil
        guard let u = URL(string: url) else { err = "链接无效"; busy = false; return }
        do {
            let (data, _) = try await URLSession.shared.data(from: u)
            let text = String(data: data, encoding: .utf8) ?? ""
            // base64 分享链接订阅（`.txt` + `text/plain` 面板很常见）不是 mihomo
            // 配置，但可以当场转换后预览。旧实现在这里直接拒绝并让用户「去订阅页
            // 添加」——而订阅页走的是同一条下载/校验链，于是这类订阅永远进不来。
            let normalized = ConfigStore.normalizedForProfile(text)
            let yaml = normalized.yaml.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !yaml.isEmpty, normalized.converted || yaml.contains(":") else {
                err = "下载失败或内容不是 YAML"
                busy = false; return
            }
            previewContent = normalized.yaml
            preview = M.store.previewOfContent(normalized.yaml)
            if normalized.converted {
                conversionNote = normalized.skipped.isEmpty
                    ? "已从 base64 分享链接转换为 mihomo 配置"
                    : "已转换；\(normalized.skipped.count) 条被跳过：\(normalized.skipped.joined(separator: "；"))"
            } else {
                conversionNote = nil
            }
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
    /// 非 nil = 选中的文件是 base64 分享链接订阅（.txt），已转成配置。
    @State private var conversionNote: String? = nil
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
                if let conversionNote {
                    Label(conversionNote, systemImage: "arrow.triangle.2.circlepath")
                        .font(.dsBody).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("放弃") { stage = .pick }.dsButton()
                    Spacer()
                    Button("添加到配置列表") { Task { await saveDraft(apply: false) } }.dsButton()
                        .disabled(name.isEmpty)
                    Button("导入并应用") { Task { await saveDraft(apply: true) } }
                        .dsButton(.prominent).disabled(name.isEmpty)
                        .keyboardShortcut(.defaultAction)
                }

            }
        }.padding(DS.Spacing.xl).frame(minWidth: 440, idealWidth: 480, maxWidth: 600)
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.yaml, .plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // UI-2：本 App 非沙箱（app-sandbox=false），NSOpenPanel 返回的 URL 不是
        // security-scoped——startAccessingSecurityScopedResource() 返回 false。
        // 旧实现把它放进条件链，整个导入分支被静默跳过、无任何报错。
        // 现在直接读文件；仅当返回 true 时才配对 stop（将来若沙箱化也成立）。
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            // 本地 `.txt` 也可能是 base64 分享链接订阅：转换后再预览，否则
            // 预览会显示「0 个节点」而保存时内容又突然变成可用配置。
            let normalized = ConfigStore.normalizedForProfile(content)
            draftContent = normalized.yaml
            preview = M.store.previewOfContent(normalized.yaml)
            if normalized.converted {
                conversionNote = normalized.skipped.isEmpty
                    ? "已从 base64 分享链接转换为 mihomo 配置"
                    : "已转换；\(normalized.skipped.count) 条被跳过：\(normalized.skipped.joined(separator: "；"))"
            } else {
                conversionNote = nil
            }
            if name.isEmpty { name = url.deletingPathExtension().lastPathComponent }
            stage = .preview
        } catch {
            M.showToast("读取文件失败：\(error.localizedDescription)", kind: .error)
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
    /// UI-14：写盘失败时保留弹窗并报错，不再拿旧内容去「保存并应用」。
    @State private var saveError: String? = nil
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("编辑配置").font(.dsCardLabel)
                Spacer()
                Button("取消") { dismiss() }.dsButton()
                Button("保存并应用") { saveAndApply() }
                    .dsButton(.prominent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(DS.Spacing.m)

            // 错误行固定占位（§6.4）：出现/消失不挤动编辑器与按钮。
            Text(saveError ?? " ")
                .font(.dsBody)
                .foregroundColor(saveError == nil ? .clear : DS.Palette.error)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, DS.Spacing.m)

            Divider()
            // 输入过程中只清除错误，不新报错（§6.4）。
            YAMLEditor(text: $text, onChange: { saveError = nil })
        }
        .frame(minWidth: 680, idealWidth: 720, maxWidth: 900, minHeight: 560, idealHeight: 620, maxHeight: 800)
        .onAppear { text = M.store.content(profileID) }
    }

    private func saveAndApply() {
        M.store.saveContent(profileID, text)
        // UI-14：saveContent 目前吞掉写盘错误（配置域将把返回值改为 Bool，
        // 届时直接消费返回值）。签名未变前先读回验证：磁盘内容不等于提交
        // 内容 = 写入未生效，保留弹窗报错，绝不继续 apply 旧内容。
        guard M.store.content(profileID) == text else {
            saveError = "保存失败：磁盘写入未生效，请检查磁盘空间与权限后重试"
            return
        }
        if M.store.activeID == profileID { M.activateProfile(profileID) }
        dismiss()
    }
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
        // P3：颜色走 DS.Palette（Light/Dark 动态色），不再用 raw 系统色。
        // NSColor(Color) 对 Color(nsColor:) 取回原动态 NSColor，主题切换仍自适应；
        // 注释走系统语义灰（design.md §3.1 文本优先系统语义）。
        func highlight() {
            guard let tv = textView, let storage = tv.textStorage else { return }
            let full = tv.string as NSString
            let sel = tv.selectedRange()
            storage.beginEditing()
            storage.addAttribute(.foregroundColor, value: NSColor.textColor, range: NSRange(location: 0, length: full.length))
            storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), range: NSRange(location: 0, length: full.length))
            apply(#"#[^\n]*"#, .secondaryLabelColor, full, storage)                  // comments
            apply(#"^\s*[-]?\s*[\w.\-]+(?=\s*:)"#, NSColor(DS.Palette.info), full, storage)      // keys
            apply(#":\s*[\"'][^\"'\n]*[\"']"#, NSColor(DS.Palette.download), full, storage)      // quoted values
            apply(#":\s*-?\d+(\.\d+)?\b"#, NSColor(DS.Palette.warn), full, storage)             // numbers
            apply(#"\b(true|false|null)\b"#, NSColor(DS.Palette.accent), full, storage)         // literals
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

