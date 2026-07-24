import SwiftUI

// MARK: - Design System Components
//
// 原型 `app/ui.jsx` 共享原子组件的 SwiftUI 对应实现。
// 视觉基线: design_handoff_clashpow (hifi)。所有尺寸/字号/颜色走 DS token,
// 页面层不得再硬编码。

// MARK: - 徽章 / 标签

/// 地区徽章 — 原型 `.region-chip`：9.5px/800 mono，hue 着色的字/底/边三件套。
struct DSRegionChip: View {
    let code: String

    /// 原型 `REGIONS` 的 hue 表；未知地区回落 200(蓝)。
    private static let hues: [String: Double] = [
        "HK": 5, "JP": 0, "US": 250, "SG": 150, "TW": 30,
        "KR": 290, "DE": 60, "UK": 220, "GB": 220,
    ]

    private var hue: Double { Self.hues[code.uppercased()] ?? 200 }

    var body: some View {
        let tint = DS.Palette.regionTint(hue)
        Text(code.uppercased())
            .font(.dsBadge)
            .tracking(0.3)
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(DS.Shape.badge().fill(tint.opacity(0.14)))
            .overlay(DS.Shape.badge().strokeBorder(tint.opacity(0.30), lineWidth: 0.5))
    }
}

extension DSRegionChip {
    /// 从节点名推断地区码。mihomo 不返回地区字段，机场命名习惯是中文地名 /
    /// 英文地名 / 国旗 emoji，这里按关键词匹配，匹配不到返回 nil（不显示徽章）。
    static func region(from name: String) -> String? {
        let n = name.lowercased()
        let table: [(String, [String])] = [
            ("HK", ["香港", "hong kong", "hongkong", "hk", "🇭🇰"]),
            ("TW", ["台湾", "台北", "taiwan", "tw", "🇹🇼"]),
            ("JP", ["日本", "东京", "大阪", "japan", "tokyo", "jp", "🇯🇵"]),
            ("KR", ["韩国", "首尔", "korea", "seoul", "kr", "🇰🇷"]),
            ("SG", ["新加坡", "狮城", "singapore", "sg", "🇸🇬"]),
            ("US", ["美国", "洛杉矶", "圣何塞", "united states", "usa", "us", "🇺🇸"]),
            ("UK", ["英国", "伦敦", "united kingdom", "london", "uk", "🇬🇧"]),
            ("DE", ["德国", "法兰克福", "germany", "de", "🇩🇪"]),
        ]
        for (code, keys) in table where keys.contains(where: { n.contains($0) }) {
            return code
        }
        return nil
    }
}

/// 协议标签 — 原型 `.proto-tag`：10px/700 mono，低饱和 hue 着色，无底无边。
struct DSProtoTag: View {
    let type: String

    /// 原型 `PROTO_HUE`。
    private static let hues: [String: Double] = [
        "trojan": 25, "vmess": 200, "vless": 265, "shadowsocks": 150, "ss": 150,
        "hysteria2": 320, "hysteria": 320, "tuic": 300, "wireguard": 100,
        "direct": 145, "reject": 25, "group": 220, "selector": 220,
        "urltest": 220, "fallback": 220, "loadbalance": 220,
    ]

    private var hue: Double {
        Self.hues[type.lowercased().replacingOccurrences(of: "-", with: "")] ?? 220
    }

    var body: some View {
        Text(type)
            .font(.dsProtoTag)
            .foregroundStyle(DS.Palette.protoTint(hue))
            .lineLimit(1)
    }
}

/// 延迟徽章 — 原型 `.lat`：<80 good / <160 warn / 否则 bad；测速中黄色闪烁。
struct DSLatencyBadge: View {
    let ms: Int?
    var testing: Bool = false

    @State private var blink = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 原型 `latColor()` 的阈值，供表格等非徽章场景复用。
    static func color(_ ms: Int?) -> Color {
        guard let ms, ms > 0 else { return DS.Palette.textFaint }
        if ms < 80 { return DS.Palette.ok }
        if ms < 160 { return DS.Palette.warn }
        return DS.Palette.error
    }

    var body: some View {
        Group {
            if testing {
                Text("测速中…")
                    .foregroundStyle(DS.Palette.warn)
                    .opacity(blink ? 0.4 : 1)
                    .onAppear {
                        guard !reduceMotion else { return }
                        withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                            blink = true
                        }
                    }
                    .onDisappear { blink = false }
            } else if let ms, ms > 0 {
                Text("\(ms) ms")
                    .foregroundStyle(Self.color(ms))
            } else {
                Text("—").foregroundStyle(DS.Palette.textFaint)
            }
        }
        .font(.dsMonoSmBold)
        .monospacedDigit()
        .lineLimit(1)
    }
}

/// 组类型 / 只读状态徽章 — 原型 `.pg-kind`：9.5px/800 mono + 描边，无底色。
struct DSKindBadge: View {
    let text: String
    var tint: Color? = nil

    var body: some View {
        let c = tint ?? DS.Palette.textFaint
        Text(text)
            .font(.dsBadge)
            .foregroundStyle(c)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .overlay(DS.Shape.badge(4).strokeBorder(tint.map { $0.opacity(0.4) } ?? DS.Palette.borderStrong, lineWidth: 0.5))
    }
}

/// 实心语义徽章 — 用于「生效中」「自动更新」等状态。原型 accent 14% 底 + accent 字。
struct DSStatusBadge: View {
    let text: String
    var tint: Color = DS.Palette.accent

    var body: some View {
        Text(text)
            .font(.dsTagSm)
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(DS.Shape.badge().fill(tint.opacity(0.16)))
    }
}

/// 状态圆点 — 原型 `.sdot`，7px。
struct DSDot: View {
    var color: Color
    var size: CGFloat = 7

    var body: some View {
        Circle().fill(color).frame(width: size, height: size)
    }
}

// MARK: - 数值卡

/// 概览数值卡 — 原型 `.stat-card`：11px 标签 + 24px 粗值(+单位) + 10px mono 副标。
struct DSStatCard<Trailing: View>: View {
    let label: String
    let value: String
    var unit: String? = nil
    var sub: String? = nil
    var accent: Bool = false
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .font(.dsStatLabel)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.dsStatValue)
                    .tracking(-0.5)
                    .monospacedDigit()
                    .foregroundStyle(accent ? DS.Palette.accent : Color.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let unit {
                    Text(unit)
                        .font(.dsBodySemibold)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, DS.Spacing.xs)

            if let sub {
                Text(sub)
                    .font(.dsMonoTiny)
                    .foregroundStyle(DS.Palette.textFaint)
                    .lineLimit(1)
                    .padding(.top, 3)
            }

            trailing()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 13)
        .padding(.vertical, DS.Spacing.m)
        .dsCardChrome()
    }
}

extension DSStatCard where Trailing == EmptyView {
    init(label: String, value: String, unit: String? = nil, sub: String? = nil, accent: Bool = false) {
        self.init(label: label, value: value, unit: unit, sub: sub, accent: accent, trailing: { EmptyView() })
    }
}

/// 细进度条 — 原型引擎卡 `Vital` 的 5px 圆角条。
struct DSBar: View {
    let progress: Double
    var tint: Color = DS.Palette.accent
    var height: CGFloat = 5

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(DS.Palette.track)
                Capsule().fill(tint)
                    .frame(width: max(0, min(1, progress)) * geo.size.width)
            }
        }
        .frame(height: height)
    }
}

/// 指标行 — 标签 + 数值一行，下方进度条；原型引擎能效卡内部结构。
struct DSVital: View {
    let label: String
    let value: String
    var unit: String? = nil
    let progress: Double
    var sub: String? = nil
    var good: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.s) {
                Text(label).font(.dsBody).foregroundStyle(.secondary)
                Spacer(minLength: DS.Spacing.s)
                Text(value)
                    .font(.dsLabelBold)
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                if let unit {
                    Text(unit).font(.dsCaption).foregroundStyle(.secondary)
                }
            }
            DSBar(progress: progress, tint: good ? DS.Palette.ok : DS.Palette.accent)
            if let sub {
                Text(sub).font(.dsMonoTiny).foregroundStyle(DS.Palette.textFaint).lineLimit(1)
            }
        }
    }
}

// MARK: - 控件

/// 筛选 chip — 原型 `.chip`：胶囊、11px/600，选中填 accent。
/// `count` 显示在标签下方（原型连接页筛选器写法）。
struct DSFilterChip: View {
    let title: String
    var count: Int? = nil
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            // 标签 + 数字同一行——两行堆叠时胶囊高度被撑到跟宽度差不多，
            // 4 个筛选项排成一排会变成一串圆滚滚的团，不像同一家族的胶囊控件。
            // 数字退到一个更淡、更小的徽标位置，视觉上仍是"标签为主"，不是
            // 两个并列的信息块。
            HStack(spacing: 5) {
                Text(title)
                    .font(.dsCaptionBold)
                    .lineLimit(1)
                if let count {
                    Text("\(count)")
                        .font(.dsCountSm)
                        .monospacedDigit()
                        .foregroundStyle(selected ? DS.Palette.accentInk.opacity(0.75)
                                                   : DS.Palette.textFaint)
                }
            }
            .foregroundStyle(selected ? DS.Palette.accentInk : Color.secondary)
            .padding(.horizontal, DS.Spacing.m - 2)
            .frame(height: DS.Layout.segHeight)
            .background(
                Group {
                    if selected {
                        Capsule().dsElevatedFill(DS.Palette.accent)
                    } else {
                        Capsule().fill(DS.Palette.controlBg)
                    }
                }
            )
            .overlay(Capsule().strokeBorder(selected ? Color.white.opacity(0.18) : DS.Palette.borderStrong,
                                            lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 图标槽 — 原型 `.pg-ico` / `.prof-ico` / `.iface-ico` / `.hero-ico`。
/// `tint` 为 nil 时用 controlBg 底 + accent 图标；否则实心 tint 底 + 白色图标。
struct DSIconSlot: View {
    let systemImage: String
    var size: CGFloat = DS.Layout.iconSlotSm
    var radius: CGFloat = DS.Radius.node
    var tint: Color? = nil
    var filled: Bool = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return Image(systemName: systemImage)
            .font(DS.Icon.font(size * 0.46, weight: .medium))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(filled ? Color.white : (tint ?? DS.Palette.accent))
            .frame(width: size, height: size)
            .background(shape.fill(filled ? (tint ?? DS.Palette.accent) : DS.Palette.controlBg))
    }
}

/// 开关 — 全 App 唯一的 Toggle 外观。
///
/// 直接写 `Toggle` 时 `controlSize` 很容易各处不一（regular / small / mini 都出现过），
/// 同一个表单里开关大小就会跳。所有开关都必须走这里。
struct DSSwitch: View {
    @Binding var isOn: Bool
    var tint: Color = DS.Palette.accent
    var disabled: Bool = false

    var body: some View {
        Toggle("", isOn: $isOn)
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()
            .tint(tint)
            .disabled(disabled)
            .opacity(disabled ? 0.55 : 1)
    }
}

/// 开关行 — 原型 `SwitchRow`：标题 + 灰色说明 + 右侧 Toggle，行间 0.5px 分隔。
struct DSSwitchRow: View {
    let title: String
    var desc: String? = nil
    var monoKey: String? = nil
    @Binding var isOn: Bool
    var tint: Color = DS.Palette.accent
    var disabled: Bool = false

    var body: some View {
        HStack(alignment: .center, spacing: DS.Spacing.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.dsCardLabel).foregroundStyle(.primary).lineLimit(1)
                if let monoKey {
                    Text(monoKey).font(.dsMonoTiny).foregroundStyle(DS.Palette.textFaint).lineLimit(1)
                }
                if let desc {
                    Text(desc).font(.dsCaption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: DS.Spacing.m)
            DSSwitch(isOn: $isOn, tint: tint, disabled: disabled)
        }
        .opacity(disabled ? 0.5 : 1)
        .padding(.vertical, DS.Spacing.s + 1)
    }
}

/// 表单行 — 原型 `.form-row`：左侧中文名 + mono key(200pt 固定宽)，右侧控件，
/// 行底 0.5px 分隔线。
struct DSFormRow<Control: View>: View {
    let title: String
    var monoKey: String? = nil
    var desc: String? = nil
    var disabled: Bool = false
    var divider: Bool = true
    /// 竖排：标签在上、控件在下（列表类控件用）。
    var stacked: Bool = false
    @ViewBuilder var control: () -> Control

    var body: some View {
        Group {
            if stacked {
                VStack(alignment: .leading, spacing: DS.Spacing.s) {
                    labelBlock
                    control().frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                HStack(alignment: .center, spacing: DS.Spacing.m) {
                    // 双列布局下列宽减半，200pt 死宽会把控件挤没 ——
                    // 给一个可压缩区间，窄列时先让标签让位。
                    labelBlock.frame(minWidth: 120, idealWidth: 200, maxWidth: 200,
                                     alignment: .leading)
                    control().frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .opacity(disabled ? 0.5 : 1)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            if divider {
                Rectangle().fill(DS.Palette.border).frame(height: 0.5)
            }
        }
    }

    private var labelBlock: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.dsBodySemibold).foregroundStyle(.primary).lineLimit(1)
            if let monoKey {
                Text(monoKey).font(.dsMonoTiny).foregroundStyle(DS.Palette.textFaint).lineLimit(1)
            }
            if let desc {
                Text(desc).font(.dsCaption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }
}

/// 复制按钮 — 原型 `.copy-btn`：26px 高、11px/600、hover 变 accent。
struct DSCopyButton: View {
    var title: String = "复制"
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "doc.on.doc")
                    .font(DS.Icon.font(11, weight: .semibold))
                Text(title).font(.dsCaptionBold)
            }
            .foregroundStyle(hovering ? DS.Palette.accentInk : Color.secondary)
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(DS.Shape.control().fill(hovering ? DS.Palette.accent : DS.Palette.controlBg))
            .overlay(DS.Shape.control().strokeBorder(hovering ? Color.clear : DS.Palette.borderStrong, lineWidth: 0.5))
            .contentShape(DS.Shape.control())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// 图标按钮 — 原型 `.icon-btn`：28×28、elev 底、borderStrong 边。
struct DSIconButton: View {
    let systemImage: String
    var tint: Color? = nil
    var help: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(DS.Icon.font(DS.Icon.sm, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(tint ?? Color.primary)
                .frame(width: DS.Layout.controlHeight, height: DS.Layout.controlHeight)
                .background(DS.Shape.control().fill(DS.Palette.controlBg))
                .overlay(DS.Shape.control().strokeBorder(DS.Palette.borderStrong, lineWidth: 0.5))
                .contentShape(DS.Shape.control())
        }
        .buttonStyle(.plain)
        .help(help ?? "")
    }
}

// MARK: - 表格

/// 表头单元 — 原型 `.tbl thead th`：10.5px/700 大写 + 0.4 字距。
struct DSTableHead: View {
    let title: String
    var alignment: Alignment = .leading
    var width: CGFloat? = nil

    var body: some View {
        Text(title)
            .font(.dsTableHeader)
            .tracking(0.4)
            .textCase(.uppercase)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(width: width, alignment: alignment)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: alignment)
    }
}

/// 表格行容器 — 固定 `rowHeight`、hover 高亮、底部 0.5px 分隔线。
struct DSTableRow<Content: View>: View {
    var height: CGFloat = DS.Layout.rowHeight
    var selected: Bool = false
    @ViewBuilder var content: () -> Content
    @State private var hovering = false

    var body: some View {
        content()
            .padding(.horizontal, DS.Spacing.s + 2)
            .frame(height: height)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? DS.Palette.accentSoft : (hovering ? DS.Palette.rowHover : Color.clear))
            .overlay(alignment: .bottom) {
                Rectangle().fill(DS.Palette.separator).frame(height: 0.5)
            }
            .onHover { hovering = $0 }
    }
}

// MARK: - 卡片头

/// 卡头 — 原型 `.card-head`：uppercase 11px/700 灰标题 + 右侧动作，底部 0.5px 分隔。
struct DSCardHead<Actions: View>: View {
    let title: String
    var count: String? = nil
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(spacing: DS.Spacing.s) {
            Text(title)
                .font(.dsCardTitle)
                .tracking(0.4)
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: DS.Spacing.s)
            if let count {
                Text(count).font(.dsCaption).foregroundStyle(DS.Palette.textFaint)
            }
            actions()
        }
        .padding(.horizontal, DS.Spacing.m)
        .padding(.vertical, DS.Spacing.s + 2)
        .background(DS.Palette.cardHeadBg)
        .overlay(alignment: .bottom) {
            Rectangle().fill(DS.Palette.border).frame(height: 0.5)
        }
    }
}

extension DSCardHead where Actions == EmptyView {
    init(title: String, count: String? = nil) {
        self.init(title: title, count: count, actions: { EmptyView() })
    }
}

// MARK: - 分区容器

/// 带卡头的分区卡 — `DSCardHead` + 内容，整体走 `dsCardChrome`。
struct DSSection<Content: View, Actions: View>: View {
    let title: String
    var count: String? = nil
    var pad: Bool = true
    @ViewBuilder var actions: () -> Actions
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            DSCardHead(title: title, count: count, actions: actions)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(pad ? DS.Spacing.m : 0)
        }
        .dsCardChrome()
    }
}

extension DSSection where Actions == EmptyView {
    init(title: String, count: String? = nil, pad: Bool = true, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, count: count, pad: pad, actions: { EmptyView() }, content: content)
    }
}

// MARK: - 分隔

/// 行间 0.5px 分隔线 — 原型表单/开关组内部分隔。
struct DSRowDivider: View {
    var body: some View {
        Rectangle().fill(DS.Palette.border).frame(height: 0.5)
    }
}

// MARK: - Preview

#Preview("DS Components") {
    ScrollView {
        VStack(alignment: .leading, spacing: DS.Spacing.l) {
            HStack(spacing: DS.Spacing.s) {
                DSRegionChip(code: "HK")
                DSRegionChip(code: "JP")
                DSRegionChip(code: "US")
                DSRegionChip(code: "SG")
                DSProtoTag(type: "Trojan")
                DSProtoTag(type: "VLESS")
                DSKindBadge(text: "URL-TEST")
                DSStatusBadge(text: "生效中")
            }
            HStack(spacing: DS.Spacing.l) {
                DSLatencyBadge(ms: 38)
                DSLatencyBadge(ms: 120)
                DSLatencyBadge(ms: 320)
                DSLatencyBadge(ms: nil, testing: true)
            }
            HStack(spacing: DS.Spacing.m) {
                DSStatCard(label: "实时下载", value: "2.9", unit: "MB/s", sub: "▼ 31.60 GB 累计", accent: true)
                DSStatCard(label: "活跃连接", value: "48", sub: "TCP 37 · UDP 11")
            }
            DSSection(title: "引擎 · 系统能效") {
                VStack(spacing: DS.Spacing.m) {
                    DSVital(label: "内存占用", value: "77", unit: "MB", progress: 0.55, sub: "引擎 46 · GUI 31")
                    DSVital(label: "UI 帧率", value: "120", unit: "fps", progress: 1.0, sub: "无掉帧", good: true)
                }
            }
            HStack(spacing: DS.Spacing.s) {
                DSFilterChip(title: "全部", count: 48, selected: true) {}
                DSFilterChip(title: "代理", count: 33, selected: false) {}
                DSCopyButton {}
                DSIconButton(systemImage: "arrow.clockwise") {}
            }
        }
        .padding(DS.Spacing.xl)
    }
    .frame(width: 620, height: 700)
    .background(DS.Palette.windowBg)
}
