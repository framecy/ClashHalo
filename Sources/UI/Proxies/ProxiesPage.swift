import SwiftUI

// MARK: - Proxies

struct ProxiesPage: View {
    @EnvironmentObject var M: AppModel
    @State private var collapsed: Set<String> = []
    @AppStorage("proxies.displayMode") private var displayMode = "list" // list | grid

    var body: some View {
        VStack(spacing: 0) {
            PageToolbar {
                DSSegmentedControl(selection: $displayMode, choices: [
                    DSChoice("", "list", systemImage: "list.bullet"),
                    DSChoice("", "grid", systemImage: "square.grid.2x2")
                ])
                .frame(width: 64)

                if displayMode == "list" {
                    Button {
                        collapsed = collapsed.count == M.groups.count ? [] : Set(M.groups.map(\.id))
                    } label: { Label(collapsed.count == M.groups.count ? "全部展开" : "全部折叠", systemImage: "rectangle.expand.vertical") }
                    .dsButton()

                }

                Button {
                    M.closeOnSwitch.toggle()
                } label: {
                    Label("切换断连", systemImage: "bolt.horizontal.circle")
                }
                .dsButton(M.closeOnSwitch ? .prominent : .secondary)
                .help("切换节点时自动断开所有现有连接，使流量立即走新节点")

                Button { M.testAll() } label: { Label("全部测速", systemImage: "bolt.fill") }
                    .dsButton(.prominent)

            }

            if let err = M.proxiesError {
                VStack(spacing: DS.Spacing.m) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(DS.Icon.font(DS.Icon.xl))
                        .foregroundStyle(.secondary.opacity(0.45))
                        .symbolRenderingMode(.hierarchical)
                    Text("加载代理失败")
                        .font(.dsBody)
                        .foregroundStyle(.secondary)
                    Text(err)
                        .font(.dsMono)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, DS.Layout.pageContentInset)
                    Button {
                        Task { await M.refreshProxies() }
                    } label: {
                        Label("重试", systemImage: "arrow.clockwise")
                    }
                    .dsButton()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else if M.groups.isEmpty {
                if M.proxiesLoading {
                    ContentUnavailable("正在加载代理…", "arrow.triangle.2.circlepath")
                } else {
                    ContentUnavailable("暂无可用代理组", "diamond.circle")
                }
            } else {
                ScrollView {
                    if displayMode == "grid" {
                        LazyVGrid(
                            columns: [
                                GridItem(.flexible(), spacing: DS.Spacing.m),
                                GridItem(.flexible(), spacing: DS.Spacing.m)
                            ],
                            spacing: DS.Spacing.m
                        ) {
                            ForEach(M.groups) { g in gridGroupCard(g) }
                        }
                        .padding(.horizontal, DS.Layout.pageContentInset)
                        .padding(.top, DS.Spacing.l)
                        .padding(.bottom, DS.Spacing.xxl)
                    } else {
                        LazyVStack(spacing: DS.Spacing.m) {
                            ForEach(M.groups) { g in groupCard(g) }
                        }
                        .padding(.horizontal, DS.Layout.pageContentInset)
                        .padding(.top, DS.Spacing.l)
                        .padding(.bottom, DS.Spacing.xxl)
                    }
                }
            }
        }
        .onAppear {
            Task {
                await M.refreshProxies()
            }
        }
    }

    private func groupIcon(_ type: String) -> String {
        switch type {
        case "URLTest": return "bolt.badge.automatic.fill"
        case "Fallback": return "arrow.uturn.down.circle.fill"
        case "LoadBalance": return "arrow.left.arrow.right.circle.fill"
        case "Selector": return "hand.tap.fill"
        default: return "circle.grid.2x2.fill"
        }
    }

    /// Compact Grid Card layout for multi-column grid display mode.
    private func gridGroupCard(_ g: ProxyGroup) -> some View {
        let cur = g.now
        let curDelay = M.nodes[cur]?.delay ?? 0
        let busy = g.all.contains { M.testing.contains($0) }
        let c = DS.Palette.accent

        return Card {
            VStack(alignment: .leading, spacing: DS.Spacing.s) {
                HStack(spacing: DS.Spacing.s) {
                    Image(systemName: groupIcon(g.type)).font(.dsBody).foregroundColor(c).frame(width: DS.Icon.sm)
                    Text(g.name).font(.dsBodySemibold).lineLimit(1)
                    Spacer(minLength: 0)
                    Button { M.testGroup(g) } label: { Image(systemName: "bolt") }
                        .buttonStyle(.borderless).controlSize(.small).font(.dsBody)
                }

                HStack(spacing: DS.Spacing.xs) {
                    DSMenuPicker(selection: Binding(
                        get: { g.now },
                        set: { if g.selectable { M.select(group: g.id, name: $0) } }
                    ), choices: g.all.map { DSChoice($0, $0) })
                    .frame(maxWidth: .infinity)
                    if curDelay > 0 {
                        Text("\(curDelay)ms").font(.dsMono).foregroundColor(delayColor(curDelay))
                    }
                    if busy {
                        ProgressView().controlSize(.mini).scaleEffect(0.5)
                    }
                    Spacer(minLength: 0)
                    Text("\(g.all.count) 节点").font(.dsBody).foregroundColor(.secondary)
                }
            }
        }
    }

    private func groupCard(_ g: ProxyGroup) -> some View {
        let isOpen = !collapsed.contains(g.id)
        let cur = g.now
        let curDelay = M.nodes[cur]?.delay ?? 0
        return Card {
            VStack(spacing: 0) {
                Button {
                    withAnimation(DS.Motion.micro) {
                        if isOpen { collapsed.insert(g.id) } else { collapsed.remove(g.id) }
                    }
                } label: {
                    HStack(spacing: DS.Spacing.s) {
                        Image(systemName: "chevron.right").font(.dsBody).foregroundColor(.secondary)
                            .rotationEffect(.degrees(isOpen ? 90 : 0))
                        Image(systemName: groupIcon(g.type)).font(.dsBody).foregroundColor(DS.Palette.accent).frame(width: DS.Icon.lg)
                        VStack(alignment: .leading, spacing: DS.Spacing.xs / 2) {
                            HStack(spacing: DS.Spacing.s) {
                                Text(g.name).font(.dsBodySemibold)
                                Text(g.type).font(.dsBody).foregroundColor(.secondary)
                                    .padding(.horizontal, DS.Spacing.xs)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(DS.Palette.hairline))
                            }
                            HStack(spacing: DS.Spacing.xs) {
                                Text(cur).font(.dsBody).foregroundColor(DS.Palette.accent).lineLimit(1)
                                if curDelay > 0 { Text("\(curDelay)ms").font(.dsMono).foregroundColor(delayColor(curDelay)) }
                            }
                        }
                        Spacer(minLength: 0)
                        Button { M.testGroup(g) } label: { Image(systemName: "bolt") }
                            .buttonStyle(.borderless).controlSize(.small).help("测速")
                        Text("\(g.all.count)").font(.dsBody)
                            .padding(.horizontal, DS.Spacing.s)
                            .padding(.vertical, DS.Spacing.xs / 2)
                            .background(Capsule().fill(DS.Palette.hairline))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isOpen {
                    Divider().overlay(DS.Palette.separator).padding(.vertical, DS.Spacing.s)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 168), spacing: DS.Spacing.s)], spacing: DS.Spacing.s) {
                        ForEach(g.all, id: \.self) { name in nodeChip(group: g, name: name) }
                    }
                }
            }
        }
    }

    private func nodeChip(group: ProxyGroup, name: String) -> some View {
        let on = (group.now) == name
        let node = M.nodes[name]
        let isGroup = M.groups.contains { $0.id == name }
        let delay = node?.delay ?? 0
        let busy = M.testing.contains(name)
        return Button {
            if group.selectable { M.select(group: group.id, name: name) }
        } label: {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                HStack(spacing: DS.Spacing.s) {
                    Text(name).font(on ? .dsBodySemibold : .dsBody)
                        .foregroundColor(on ? DS.Palette.accent : .primary).lineLimit(1)
                    Spacer(minLength: DS.Spacing.xs / 2)
                    if on { Image(systemName: "checkmark.circle.fill").font(.dsBody).foregroundColor(DS.Palette.accent) }
                }
                HStack(spacing: DS.Spacing.s) {
                    Text(isGroup ? "组" : (node?.type ?? "—")).font(.dsBody).foregroundColor(.secondary)
                    Spacer(minLength: DS.Spacing.xs / 2)
                    if busy {
                        ProgressView().controlSize(.mini).scaleEffect(0.55)
                    } else if !isGroup {
                        Circle().fill(delayColor(delay)).frame(width: 6, height: 6)
                        Text(fmtDelay(delay)).font(.dsMono).foregroundColor(delayColor(delay))
                    } else {
                        Image(systemName: "chevron.right.circle").font(.dsBody).foregroundColor(.secondary)
                    }
                }
            }
            .padding(.horizontal, DS.Spacing.m)
            .padding(.vertical, DS.Spacing.s)
            .background(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).fill(on ? DS.Palette.accent.opacity(0.12) : DS.Palette.fillFaint))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).stroke(on ? DS.Palette.accent.opacity(0.45) : Color.clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!group.selectable)
    }
}
