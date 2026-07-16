import SwiftUI

struct RulesPage: View {
    @EnvironmentObject var M: AppModel
    @StateObject private var model = RuleEditorModel(targetFilePath: "")
    @State private var q = ""
    @State private var selection = Set<UUID>()
    @State private var showingForm = false
    @State private var editingNode: RuleNode? = nil

    private func matches(_ r: RuleNode) -> Bool {
        let pg = r.proxyGroup ?? ""
        return q.isEmpty || "\(r.type.rawValue)\(r.match)\(pg)".localizedCaseInsensitiveContains(q)
    }

    var body: some View {
        let rows = model.nodes.filter(matches)

        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: DS.Spacing.m) {
                HStack(spacing: DS.Spacing.s) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                        .font(.dsBody)
                    TextField("搜索规则类型 / 内容 / 策略", text: $q)
                        .textFieldStyle(.plain)
                        .font(.dsBody)
                }
                .dsSearchFieldChrome(maxWidth: 320)

                Spacer(minLength: 0)

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
                    editingNode = nil
                    showingForm = true
                }) {
                    Label("添加规则", systemImage: "plus")
                }
                .dsButton(.prominent)

            }
            .padding(.horizontal, DS.Layout.pageContentInset)
            .padding(.vertical, DS.Spacing.m)
            .background(DS.Palette.chromeBg)

            Divider()

            if let err = model.errorMessage {
                ContentUnavailable("加载出错: \(err)", "exclamationmark.triangle")
                .frame(maxHeight: .infinity)
            } else if model.nodes.isEmpty {
                ContentUnavailable("没有规则 (未找到 rules: 节点)", "list.bullet.rectangle")
                .frame(maxHeight: .infinity)
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
        .sheet(isPresented: $showingForm) {
            RuleFormView(existingNode: editingNode, proxyGroups: M.groups.map { $0.name }) { newNode in
                if editingNode != nil {
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
            Toggle("", isOn: Binding(
                get: { r.isEnabled },
                set: { _ in
                    model.toggleNode(id: r.id)
                    saveAndReloadKernel()
                }
            ))
            .labelsHidden()

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
                editingNode = r
                showingForm = true
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

    private func saveAndReloadKernel() {
        if model.save() {
            M.reloadActiveConfig()
        }
    }
}
