import SwiftUI

struct RulesPage: View {
    @EnvironmentObject var M: AppModel
    @StateObject private var model = RuleEditorModel(targetFilePath: "")
    @State private var q = ""
    @State private var selection = Set<UUID>()
    /// 弹窗目标。用 `.sheet(item:)` 而不是 `.sheet(isPresented:)`：
    /// `RuleFormView` 的 `@State`（type/match/action…）是在 `init` 里赋初值的，
    /// 而 SwiftUI 只会在**视图身份首次出现**时采用初值。用 isPresented 时弹窗内容
    /// 身份不变，第一次如果开的是「添加规则」（match 为空），之后每次「编辑」都会
    /// 沿用那次空值——这就是「编辑弹窗没带入原匹配内容」的根因。
    /// 每次赋值生成新 UUID → 新身份 → 重新走 init。
    struct RuleEditTarget: Identifiable {
        let id = UUID()
        let node: RuleNode?
        /// 打开弹窗那一刻的真实目标名快照（策略组 + 节点 + 内置 + config.yaml 里的组）。
        /// 用快照而不是每次求值：`AppModel.ruleTargetNames` 会读一次 config.yaml，
        /// 不能放在 body / sheet 闭包的渲染路径上反复执行。
        let knownTargets: Set<String>
        /// 同一刻的节点名快照（内存态，无读盘），供目标下拉区分节点与组（CFG-17）。
        let nodeNames: Set<String>
    }
    @State private var editTarget: RuleEditTarget? = nil
    /// UI-10：删除确认（批量与单条共用）。此前「删除」直接执行，
    /// 其余破坏性操作（删订阅/删转发/清空配置）都有确认弹窗。
    @State private var pendingDeleteIDs: Set<UUID> = []
    @State private var showDeleteConfirm = false

    private func matches(_ r: RuleNode) -> Bool {
        let pg = r.proxyGroup ?? ""
        return q.isEmpty || "\(r.type.rawValue)\(r.match)\(pg)".localizedCaseInsensitiveContains(q)
    }

    var body: some View {
        let rows = model.nodes.filter(matches)

        VStack(spacing: 0) {
            // P2-3：手搓顶栏改为共享 PageToolbar（左侧搜索，右侧批量操作/刷新/添加）
            PageToolbar(leading: {
                HStack(spacing: DS.Spacing.s) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                        .font(.dsBody)
                    TextField("搜索规则类型 / 内容 / 策略", text: $q)
                        .textFieldStyle(.plain)
                        .font(.dsBody)
                }
                .dsSearchFieldChrome(maxWidth: 320)
            }, actions: {
                if !selection.isEmpty {
                    Text("已选 \(selection.count) 项")
                        .font(.dsBody)
                        .foregroundColor(.secondary)

                    // UI-9：内核 busy 时所有写操作禁用——保存事务本身抢不到锁
                    // 只会弹 toast，按钮看起来能点却必然失败，不如直接禁用。
                    Button("启用") {
                        model.toggleNodes(ids: selection, isEnabled: true)
                        saveAndReloadKernel()
                    }
                    .dsButton()
                    .disabled(M.engine.isBusy)


                    Button("禁用") {
                        model.toggleNodes(ids: selection, isEnabled: false)
                        saveAndReloadKernel()
                    }
                    .dsButton()
                    .disabled(M.engine.isBusy)


                    Button("删除") {
                        pendingDeleteIDs = selection
                        showDeleteConfirm = true
                    }
                    .dsButton(.destructive)
                    .disabled(M.engine.isBusy)

                }

                Button { reloadModel() } label: { Label("刷新", systemImage: "arrow.clockwise") }
                    .dsButton()
                    .disabled(M.engine.isBusy)


                Button(action: {
                    editTarget = RuleEditTarget(node: nil, knownTargets: M.ruleTargetNames,
                                                nodeNames: Set(M.nodes.keys))
                }) {
                    Label("添加规则", systemImage: "plus")
                }
                .dsButton(.prominent)
                .disabled(M.engine.isBusy)
            })

            if let err = model.errorMessage {
                ContentUnavailable("加载出错: \(err)", "exclamationmark.triangle")
            } else if model.nodes.isEmpty {
                ContentUnavailable("没有规则 (未找到 rules: 节点)", "list.bullet.rectangle")
            } else {
                List(selection: $selection) {
                    ForEach(rows) { r in
                        row(r).tag(r.id)
                    }
                    .onMove { indices, newOffset in
                        // Only allow move when not filtering to prevent data corruption
                        if q.isEmpty {
                            model.nodes.move(fromOffsets: indices, toOffset: newOffset)
                            saveAndReloadKernel()
                        }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }
        }
        .onAppear {
            reloadModel()
        }
        .onChange(of: M.engine.configFilePath) { _ in
            reloadModel()
        }
        // Path is stable across profile/gateway/rule rewrites; epoch tracks content.
        .onChange(of: M.configContentEpoch) { _ in
            reloadModel()
        }
        .sheet(item: $editTarget) { target in
            // `knownTargets` 供保存前的存在性校验：规则引用了已被删除的策略组/节点时，
            // 内核 reload 会拒绝整份配置（用户只看到一条英文报错），这里在表单里拦住。
            RuleFormView(existingNode: target.node,
                         proxyGroups: M.groups.map { $0.name },
                         knownTargets: target.knownTargets,
                         nodeNames: target.nodeNames) { newNode, finished in
                if target.node != nil {
                    model.updateNode(id: newNode.id, with: newNode)
                } else {
                    model.addNode(newNode)
                }
                // UI-9：保存失败（写入被拒 / reload 回滚 / 抢不到锁）时回滚
                // 内存模型，并让表单保留弹窗——编辑内容不丢。
                M.applyRuleEditorSave(save: { self.model.save() }) { ok in
                    if !ok { self.reloadModel() }
                    finished(ok)
                }
            }
        }
        // UI-10：删规则（批量/单条）统一走确认弹窗，对齐删订阅范式。
        .confirmationDialog("删除 \(pendingDeleteIDs.count) 条规则？",
                            isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                model.deleteNodes(ids: pendingDeleteIDs)
                selection.subtract(pendingDeleteIDs)
                pendingDeleteIDs = []
                saveAndReloadKernel()
            }
            Button("取消", role: .cancel) { pendingDeleteIDs = [] }
        } message: {
            Text("删除后会立即重载内核配置；失败会自动回滚磁盘。")
        }
    }

    private func row(_ r: RuleNode) -> some View {
        HStack(spacing: DS.Spacing.s) {
            DSCompactSwitch(isOn: r.isEnabled, isEnabled: !M.engine.isBusy, accessibilityText: "启用规则") {
                model.toggleNode(id: r.id)
                saveAndReloadKernel()
            }

            Text(r.type.rawValue).font(.dsBodyMedium)
                .padding(.horizontal, DS.Spacing.s - 2).padding(.vertical, 2)
                .background(Capsule().fill(DS.Palette.hairline))
                .frame(width: 150, alignment: .leading)
                .opacity(r.isEnabled ? 1.0 : 0.5)

            Text(r.match.isEmpty ? "—" : r.match)
                .font(.dsMono).lineLimit(1)
                .strikethrough(!r.isEnabled)
                .opacity(r.isEnabled ? 1.0 : 0.5)

            Spacer()

            let actionStr = r.action == .proxy ? (r.proxyGroup ?? "PROXY") : r.action.rawValue
            Text(actionStr).font(.dsBody).foregroundColor(DS.Palette.accent)
                .opacity(r.isEnabled ? 1.0 : 0.5)
        }
        .padding(.vertical, DS.Spacing.xs)
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                editTarget = RuleEditTarget(node: r, knownTargets: M.ruleTargetNames,
                                            nodeNames: Set(M.nodes.keys))
            } label: { Label("编辑", systemImage: "pencil") }
                .disabled(M.engine.isBusy)

            Button {
                model.toggleNode(id: r.id)
                saveAndReloadKernel()
            } label: { Label(r.isEnabled ? "禁用" : "启用", systemImage: r.isEnabled ? "eye.slash" : "eye") }
                .disabled(M.engine.isBusy)

            Divider()

            Button(role: .destructive) {
                pendingDeleteIDs = [r.id]
                showDeleteConfirm = true
            } label: { Label("删除", systemImage: "trash") }
                .disabled(M.engine.isBusy)
        }
    }

    private func reloadModel() {
        if !M.engine.configFilePath.isEmpty {
            model.setTargetPath(M.engine.configFilePath)
            model.load()
        }
    }

    /// Transactional save: isBusy + disk backup + reload (or disk-only when
    /// kernel is down) + refreshRules. On reload failure the disk is rolled back
    /// and the in-memory model is reloaded from the restored file.
    private func saveAndReloadKernel() {
        M.applyRuleEditorSave(save: { self.model.save() }) { ok in
            if !ok { self.reloadModel() }
        }
    }
}
