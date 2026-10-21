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
    }
    @State private var editTarget: RuleEditTarget? = nil

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

                    Button("启用") {
                        model.toggleNodes(ids: selection, isEnabled: true)
                        saveAndReloadKernel()
                    }
                    .dsButton()


                    Button("禁用") {
                        model.toggleNodes(ids: selection, isEnabled: false)
                        saveAndReloadKernel()
                    }
                    .dsButton()


                    Button("删除") {
                        model.deleteNodes(ids: selection)
                        selection.removeAll()
                        saveAndReloadKernel()
                    }
                    .dsButton(.destructive)

                }

                Button { reloadModel() } label: { Label("刷新", systemImage: "arrow.clockwise") }
                    .dsButton()


                Button(action: {
                    editTarget = RuleEditTarget(node: nil, knownTargets: M.ruleTargetNames)
                }) {
                    Label("添加规则", systemImage: "plus")
                }
                .dsButton(.prominent)
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
                         knownTargets: target.knownTargets) { newNode in
                if target.node != nil {
                    model.updateNode(id: newNode.id, with: newNode)
                } else {
                    model.addNode(newNode)
                }
                saveAndReloadKernel()
            }
        }
    }

    private func row(_ r: RuleNode) -> some View {
        HStack(spacing: DS.Spacing.s) {
            DSCompactSwitch(isOn: r.isEnabled, accessibilityText: "启用规则") {
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
                editTarget = RuleEditTarget(node: r, knownTargets: M.ruleTargetNames)
            } label: { Label("编辑", systemImage: "pencil") }

            Button {
                model.toggleNode(id: r.id)
                saveAndReloadKernel()
            } label: { Label(r.isEnabled ? "禁用" : "启用", systemImage: r.isEnabled ? "eye.slash" : "eye") }

            Divider()

            Button(role: .destructive) {
                model.deleteNodes(ids: [r.id])
                saveAndReloadKernel()
            } label: { Label("删除", systemImage: "trash") }
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
