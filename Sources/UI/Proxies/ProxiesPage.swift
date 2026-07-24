import SwiftUI

// MARK: - Proxies
//
// 视觉基线：design_handoff_clashpow 02-proxies。
// 组卡 `.pg-card`（图标槽 + 名称 + kind 徽章 + 当前节点 + 测速/展开）
// → 展开后 `.pg-grid` 铺节点卡 `.node`（地区徽章 + 协议标签 + 延迟徽章）。

struct ProxiesPage: View {
    @EnvironmentObject var M: AppModel
    @State private var collapsed: Set<String> = []
    @AppStorage("proxies.displayMode") private var displayMode = "list" // list | grid

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Spacing.m) {
                PageHead(title: "代理") {
                    DSSegmentedControl(selection: $displayMode, choices: [
                        DSChoice("", "list", systemImage: "list.bullet"),
                        DSChoice("", "grid", systemImage: "square.grid.2x2")
                    ])
                    .frame(width: 72)

                    if displayMode == "list" {
                        Button {
                            collapsed = collapsed.count == M.groups.count ? [] : Set(M.groups.map(\.id))
                        } label: {
                            Label(collapsed.count == M.groups.count ? "全部展开" : "全部折叠",
                                  systemImage: "rectangle.expand.vertical")
                        }
                        .dsButton()
                    }

                    Button { M.closeOnSwitch.toggle() } label: {
                        Label("切换断连", systemImage: "bolt.horizontal.circle")
                    }
                    .dsButton(M.closeOnSwitch ? .prominent : .secondary)
                    .help("切换节点时自动断开所有现有连接，使流量立即走新节点")

                    Button { Task { await M.refreshProxies() } } label: {
                        Label("刷新", systemImage: "arrow.clockwise")
                    }
                    .dsButton()

                    Button { M.testAll() } label: { Label("全部测速", systemImage: "bolt.fill") }
                        .dsButton(.prominent)
                }
                .padding(.horizontal, -DS.Layout.pageContentInset)

                content
            }
            .padding(.horizontal, DS.Layout.pageContentInset)
            .padding(.bottom, 26)
        }
        .onAppear {
            Task { await M.refreshProxies() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let err = M.proxiesError {
            errorState(err)
        } else if M.groups.isEmpty {
            if M.proxiesLoading {
                ContentUnavailable("正在加载代理…", "arrow.triangle.2.circlepath")
                    .frame(minHeight: 320)
            } else {
                ContentUnavailable("暂无可用代理组", "diamond.circle")
                    .frame(minHeight: 320)
            }
        } else if displayMode == "grid" {
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: DS.Spacing.m),
                          GridItem(.flexible(), spacing: DS.Spacing.m)],
                spacing: DS.Spacing.m
            ) {
                ForEach(M.groups) { g in gridGroupCard(g) }
            }
        } else {
            LazyVStack(spacing: DS.Spacing.m) {
                ForEach(M.groups) { g in groupCard(g) }
            }
        }
    }

    private func errorState(_ err: String) -> some View {
        VStack(spacing: DS.Spacing.m) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(DS.Icon.font(DS.Icon.xl))
                .foregroundStyle(.secondary.opacity(0.45))
                .symbolRenderingMode(.hierarchical)
            Text("加载代理失败").font(.dsBody).foregroundStyle(.secondary)
            Text(err)
                .font(.dsMonoSm)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, DS.Layout.pageContentInset)
            Button { Task { await M.refreshProxies() } } label: {
                Label("重试", systemImage: "arrow.clockwise")
            }
            .dsButton()
        }
        .frame(maxWidth: .infinity, minHeight: 320, alignment: .center)
    }

    // MARK: 组卡

    private func groupIcon(_ type: String) -> String {
        switch type {
        case "URLTest": return "bolt.badge.automatic"
        case "Fallback": return "shield"
        case "LoadBalance": return "arrow.left.arrow.right"
        case "Selector": return "hand.tap"
        default: return "circle.grid.2x2"
        }
    }

    /// 组类型徽章文案 — 原型 `.pg-kind` 用 mihomo 原始大写形式。
    private func kindLabel(_ type: String) -> String {
        switch type {
        case "URLTest": return "URL-TEST"
        case "LoadBalance": return "LOAD-BALANCE"
        default: return type.uppercased()
        }
    }

    /// 组卡头 — 原型 `.pg-head`：图标槽 + 名称 + kind 徽章 / 当前节点 · 节点数。
    @ViewBuilder
    private func groupHeader(_ g: ProxyGroup, isOpen: Bool?, onToggle: (() -> Void)?) -> some View {
        let busy = g.all.contains { M.testing.contains($0) }

        HStack(spacing: 10) {
            DSIconSlot(systemImage: groupIcon(g.type))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: DS.Spacing.s) {
                    Text(g.name).font(.dsCardName).foregroundStyle(.primary).lineLimit(1)
                    DSKindBadge(text: kindLabel(g.type))
                }
                HStack(spacing: DS.Spacing.xs) {
                    Text("当前 ·").font(.dsCaption).foregroundStyle(.secondary)
                    Text(g.now.isEmpty ? "—" : g.now)
                        .font(.dsCaptionBold)
                        .foregroundStyle(DS.Palette.accent)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("· \(g.all.count) 个节点").font(.dsCaption).foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: DS.Spacing.s)

            if busy {
                ProgressView().controlSize(.mini).scaleEffect(DS.Progress.miniScale)
            }
            DSIconButton(systemImage: "bolt.fill", tint: DS.Palette.accent, help: "测速") {
                M.testGroup(g)
            }
            if let isOpen, let onToggle {
                Button(action: onToggle) {
                    Image(systemName: "chevron.right")
                        .font(DS.Icon.font(12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .frame(width: DS.Layout.controlHeight, height: DS.Layout.controlHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
    }

    private func groupCard(_ g: ProxyGroup) -> some View {
        let isOpen = !collapsed.contains(g.id)
        return VStack(spacing: 0) {
            groupHeader(g, isOpen: isOpen) {
                withAnimation(DS.Motion.micro) {
                    if isOpen { collapsed.insert(g.id) } else { collapsed.remove(g.id) }
                }
            }

            if isOpen {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: DS.Spacing.s)],
                          spacing: DS.Spacing.s) {
                    ForEach(g.all, id: \.self) { name in nodeCard(group: g, name: name) }
                }
                .padding(.horizontal, 13)
                .padding(.bottom, 13)
                .padding(.top, 2)
            }
        }
        .dsCardChrome()
    }

    /// Grid 显示模式：只显示组头 + 下拉选择，不铺节点卡。
    private func gridGroupCard(_ g: ProxyGroup) -> some View {
        VStack(spacing: 0) {
            groupHeader(g, isOpen: nil, onToggle: nil)

            Group {
                if g.selectable {
                    DSMenuPicker(selection: Binding(
                        get: { g.now },
                        set: { M.select(group: g.id, name: $0) }
                    ), choices: g.all.map { DSChoice($0, $0) })
                } else {
                    // URLTest/LoadBalance 这类自动选择组没有手动选择的意义——
                    // 之前这里什么都不画，卡片只剩个头，grid 模式下完全看不出
                    // 当前生效的是哪个节点。改成只读展示当前节点，和 selectable
                    // 分支占同一个位置、同一行高，两种卡片高度才能对上。
                    HStack(spacing: 6) {
                        DSDot(color: DS.Palette.accent, size: 6)
                        Text(g.now.isEmpty ? "—" : g.now)
                            .font(.dsBodySemibold)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: DS.Spacing.xs)
                        Text("\(g.all.count) 节点")
                            .font(.dsCaption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(height: DS.Layout.controlHeight)
                }
            }
            .padding(.horizontal, 13)
            .padding(.bottom, 13)
        }
        .frame(height: DS.Layout.cardHeightXs)
        .dsCardChrome()
    }

    // MARK: 节点卡

    /// 节点卡 — 原型 `.node`：名称 + (地区徽章 · 协议标签 · 延迟)，选中描 accent 边并打勾。
    private func nodeCard(group: ProxyGroup, name: String) -> some View {
        let on = group.now == name
        let node = M.nodes[name]
        let isGroup = M.groups.contains { $0.id == name }
        let delay = node?.delay ?? 0
        let busy = M.testing.contains(name)
        let region = isGroup ? nil : DSRegionChip.region(from: name)

        return Button {
            if group.selectable { M.select(group: group.id, name: name) }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.dsBodySemibold)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 6) {
                    if let region { DSRegionChip(code: region) }
                    DSProtoTag(type: isGroup ? "Group" : (node?.type ?? "—"))
                    if isGroup {
                        Text("↳ \(M.groups.first { $0.id == name }?.now ?? "—")")
                            .font(.dsMonoTiny)
                            .foregroundStyle(DS.Palette.textFaint)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        DSLatencyBadge(ms: delay > 0 ? delay : nil, testing: busy)
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, DS.Spacing.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.Shape.node().fill(on ? DS.Palette.accentSoft : DS.Palette.cardHeadBg))
            .overlay(DS.Shape.node().strokeBorder(on ? DS.Palette.accent : DS.Palette.border,
                                                  lineWidth: on ? 1 : 0.5))
            .overlay(alignment: .topTrailing) {
                if on {
                    Image(systemName: "checkmark")
                        .font(DS.Icon.font(10, weight: .bold))
                        .foregroundStyle(DS.Palette.accent)
                        .padding(.top, 7)
                        .padding(.trailing, 8)
                }
            }
            .contentShape(DS.Shape.node())
        }
        .buttonStyle(.plain)
        .disabled(!group.selectable)
    }
}
