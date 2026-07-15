import SwiftUI

// MARK: - Proxies

struct ProxiesPage: View {
    @EnvironmentObject var M: AppModel
    @State private var collapsed: Set<String> = []
    @AppStorage("proxies.displayMode") private var displayMode = "list" // list | grid

    var body: some View {
        VStack(spacing: 0) {
            PageToolbar {
                Picker("", selection: $displayMode) {
                    Image(systemName: "list.bullet").tag("list")
                    Image(systemName: "square.grid.2x2").tag("grid")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .dsToolbarControl()
                .frame(width: 56)

                if displayMode == "list" {
                    Button {
                        collapsed = collapsed.count == M.groups.count ? [] : Set(M.groups.map(\.id))
                    } label: { Label(collapsed.count == M.groups.count ? "全部展开" : "全部折叠", systemImage: "rectangle.expand.vertical") }
                    .buttonStyle(.bordered)
                    .dsToolbarControl()
                }

                Toggle(isOn: $M.closeOnSwitch) {
                    Label("切换断连", systemImage: "bolt.horizontal.circle")
                }
                .toggleStyle(.button)
                .tint(DS.Palette.accent)
                .dsToolbarControl()
                .help("切换节点时自动断开所有现有连接，使流量立即走新节点")

                Button { M.testAll() } label: { Label("全部测速", systemImage: "bolt.fill") }
                    .buttonStyle(.borderedProminent)
                    .tint(DS.Palette.accent)
                    .dsToolbarControl()
            }

            ScrollView {
                if let err = M.proxiesError {
                    VStack(spacing: 16) {
                        ContentUnavailable("加载代理失败", "exclamationmark.triangle.fill")
                        Text(err)
                            .font(.dsMono)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                        Button {
                            Task { await M.refreshProxies() }
                        } label: {
                            Label("重试", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .frame(maxHeight: .infinity)
                    .padding(.top, 80)
                } else if M.groups.isEmpty {
                    if M.proxiesLoading {
                        ContentUnavailable("正在加载代理…", "arrow.triangle.2.circlepath")
                            .frame(maxHeight: .infinity)
                    } else {
                        ContentUnavailable("暂无可用代理组", "diamond.circle")
                            .frame(maxHeight: .infinity)
                    }
                } else {
                    if displayMode == "grid" {
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                            ForEach(M.groups) { g in gridGroupCard(g) }
                        }
                        .padding(.horizontal, DS.Spacing.xl).padding(.bottom, DS.Spacing.xxl)
                    } else {
                        LazyVStack(spacing: 12) {
                            ForEach(M.groups) { g in groupCard(g) }
                        }
                        .padding(.horizontal, DS.Spacing.xl).padding(.bottom, DS.Spacing.xxl)
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
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: groupIcon(g.type)).font(.dsBody).foregroundColor(c).frame(width: 14)
                    Text(g.name).font(.dsBodySemibold).lineLimit(1)
                    Spacer()
                    Button { M.testGroup(g) } label: { Image(systemName: "bolt") }
                        .buttonStyle(.borderless).controlSize(.small).font(.dsBody)
                }

                HStack(spacing: 4) {
                    // Menu click allows picking nodes instantly via popup
                    Menu {
                        ForEach(g.all, id: \.self) { name in
                            Button {
                                if g.selectable { M.select(group: g.id, name: name) }
                            } label: {
                                HStack {
                                    if name == cur { Image(systemName: "checkmark") }
                                    Text(name)
                                    if let d = M.nodes[name]?.delay, d > 0 {
                                        Text(" (\(d)ms)")
                                    }
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(cur).font(.dsBodyMedium).foregroundColor(c).lineLimit(1)
                            if curDelay > 0 {
                                Text("\(curDelay)ms").font(.dsMono).foregroundColor(delayColor(curDelay))
                            }
                            if busy {
                                ProgressView().controlSize(.mini).scaleEffect(0.5)
                            }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .controlSize(.small)
                    Spacer()
                    Text("\(g.all.count) 节点").font(.dsBody).foregroundColor(.secondary)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func groupCard(_ g: ProxyGroup) -> some View {
        let isOpen = !collapsed.contains(g.id)
        let cur = g.now
        let curDelay = M.nodes[cur]?.delay ?? 0
        return Card {
            VStack(spacing: 0) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        if isOpen { collapsed.insert(g.id) } else { collapsed.remove(g.id) }
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "chevron.right").font(.dsBody).foregroundColor(.secondary)
                            .rotationEffect(.degrees(isOpen ? 90 : 0))
                        Image(systemName: groupIcon(g.type)).font(.dsBody).foregroundColor(DS.Palette.accent).frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(g.name).font(.dsBody).fontWeight(.semibold)
                                Text(g.type).font(.dsBody).foregroundColor(.secondary)
                                    .padding(.horizontal, DS.Spacing.xs + 1).padding(.vertical, 1)
                                    .background(Capsule().fill(DS.Palette.hairline))
                            }
                            HStack(spacing: 5) {
                                Text(cur).font(.dsBody).foregroundColor(DS.Palette.accent).lineLimit(1)
                                if curDelay > 0 { Text("\(curDelay)ms").font(.dsMono).foregroundColor(delayColor(curDelay)) }
                            }
                        }
                        Spacer()
                        Button { M.testGroup(g) } label: { Image(systemName: "bolt") }
                            .buttonStyle(.borderless).controlSize(.small).help("测速")
                        Text("\(g.all.count)").font(.dsBody)
                            .padding(.horizontal, DS.Spacing.s - 1).padding(.vertical, 2)
                            .background(Capsule().fill(DS.Palette.hairline))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isOpen {
                    Divider().padding(.vertical, DS.Spacing.s)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 168), spacing: 8)], spacing: 8) {
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
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(name).font(.dsBody).fontWeight(on ? .semibold : .regular)
                        .foregroundColor(on ? DS.Palette.accent : .primary).lineLimit(1)
                    Spacer(minLength: 2)
                    if on { Image(systemName: "checkmark.circle.fill").font(.dsBody).foregroundColor(DS.Palette.accent) }
                }
                HStack(spacing: 6) {
                    Text(isGroup ? "组" : (node?.type ?? "—")).font(.dsBody).foregroundColor(.secondary)
                    Spacer(minLength: 2)
                    if busy {
                        ProgressView().controlSize(.mini).scaleEffect(0.55)
                    } else if !isGroup {
                        Circle().fill(delayColor(delay)).frame(width: 5, height: 5)
                        Text(fmtDelay(delay)).font(.dsMono).foregroundColor(delayColor(delay))
                    } else {
                        Image(systemName: "chevron.right.circle").font(.dsBody).foregroundColor(.secondary)
                    }
                }
            }
            .padding(.horizontal, DS.Spacing.m - 2).padding(.vertical, DS.Spacing.s - 1)
            .background(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).fill(on ? DS.Palette.accent.opacity(0.12) : DS.Palette.fillFaint))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).stroke(on ? DS.Palette.accent.opacity(0.45) : Color.clear, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!group.selectable)
    }
}

