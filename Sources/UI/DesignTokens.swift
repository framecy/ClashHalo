import SwiftUI
import AppKit

// MARK: - Design Tokens
//
// Single source of truth for the ClashHalo design system.
// Spec: Docs/design.md · 视觉基线: design_handoff_clashpow 原型 (hifi)
// Theme: system Light / Dark via dynamic NSColor providers. No page-level scheme lock.
// Brand: 科技绿 accent — oklch(0.72 0.17 150) ≈ #19C37D.

enum DS {

    // MARK: Colors

    enum Palette {
        /// Build a Light/Dark dynamic color from two `NSColor`s. Single factory
        /// for every themed token below — collapses the repeated
        /// `bestMatch(from:[.darkAqua,.aqua]) == .darkAqua ? … : …` boilerplate
        /// into one place so the dark/light branch logic can never drift per color.
        static func dyn(_ name: String, light: NSColor, dark: NSColor) -> Color {
            Color(nsColor: NSColor(name: name, dynamicProvider: { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            }))
        }

        /// sRGB 8-bit hex helper — keeps the token table readable.
        static func srgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
                    green: CGFloat((hex >> 8) & 0xFF) / 255.0,
                    blue: CGFloat(hex & 0xFF) / 255.0,
                    alpha: alpha)
        }

        // MARK: Brand

        /// Brand accent — 科技绿 `oklch(0.72 0.17 150)`. Primary actions, selection, TUN-on.
        /// Dark uses the spec value; Light darkens one step so white-on-accent text
        /// still clears WCAG AA on light surfaces.
        static let accent = dyn("DS.accent", light: srgb(0x0D9E67), dark: srgb(0x19C37D))

        /// Text/icon color that sits *on* an accent fill (`--accent-ink`).
        static let accentInk = dyn("DS.accentInk", light: srgb(0xFFFFFF), dark: srgb(0x06210F))

        /// Selected list / node / chip fill over accent (`--row-sel`).
        static let accentSoft = dyn("DS.accentSoft", light: srgb(0x0D9E67, 0.15), dark: srgb(0x19C37D, 0.20))

        /// Strong accent for emphasis strokes / text on light fills.
        static let accentStrong = dyn("DS.accentStrong", light: srgb(0x0A7C51), dark: srgb(0x4FD79B))

        // MARK: Surfaces (L0–L3 + overlay)

        /// L0 — main content window background (`--bg-content`).
        static let windowBg = dyn("DS.windowBg", light: srgb(0xF3F3F5), dark: srgb(0x1C1C1E))

        /// L1 — sidebar background (`--sidebar`, vibrancy approximated opaque).
        static let sidebarBg = dyn("DS.sidebarBg", light: srgb(0xEEEEF2), dark: srgb(0x26262A))

        /// L2 — elevated card / panel surface (`--card`).
        static let cardBg = dyn("DS.cardBg", light: srgb(0xFFFFFF), dark: srgb(0x252528))

        /// L3 — control / chip / toolbar-button fill (`--elev`).
        static let controlBg = dyn("DS.controlBg", light: srgb(0xF4F4F6), dark: srgb(0x2D2D31))

        /// Recessed input / log stream / YAML surface (`--input`).
        static let inputBg = dyn("DS.inputBg", light: srgb(0xFFFFFF), dark: srgb(0x161617))

        /// Card header strip / dashed drop-zone fill (`--card-head`).
        static let cardHeadBg = dyn("DS.cardHeadBg", light: srgb(0x000000, 0.015), dark: srgb(0xFFFFFF, 0.025))

        /// Row hover wash (`--row-hover`).
        static let rowHover = dyn("DS.rowHover", light: srgb(0x000000, 0.04), dark: srgb(0xFFFFFF, 0.055))

        /// Toolbar strip / chrome band behind filters (`--titlebar`).
        static let chromeBg = dyn("DS.chromeBg", light: srgb(0xFAFAFC, 0.92), dark: srgb(0x2E2E32, 0.72))

        /// Overlay / toast material base (usually paired with ultraThinMaterial).
        static let overlayBg = dyn("DS.overlayBg", light: srgb(0xFFFFFF, 0.88), dark: srgb(0x252528, 0.88))

        // MARK: Status

        /// `--good` oklch(0.74 0.15 150)
        static let ok = dyn("DS.ok", light: srgb(0x11A86D), dark: srgb(0x2FCF8B))

        /// `--warn` oklch(0.80 0.14 80)
        static let warn = dyn("DS.warn", light: srgb(0xB5820A), dark: srgb(0xE0A72B))

        /// `--bad` oklch(0.66 0.20 25)
        static let error = dyn("DS.error", light: srgb(0xD93A2B), dark: srgb(0xF05545))

        static let info = dyn("DS.info", light: srgb(0x007AFF), dark: srgb(0x64D2FF))

        /// Upload traffic series / labels — 原型 `#5b8cff`.
        static let upload = dyn("DS.upload", light: srgb(0x3A6BE0), dark: srgb(0x5B8CFF))

        /// Download traffic series / labels — tracks the accent in the prototype.
        static let download = dyn("DS.download", light: srgb(0x0D9E67), dark: srgb(0x19C37D))

        // MARK: Network role colors (拓扑 / SD-WAN 接口色条)

        static let rolePhysical = dyn("DS.rolePhysical", light: srgb(0x2563EB), dark: srgb(0x3B82F6))

        /// 本应用 TUN — 与品牌强调色同源，强调"这条是我们的"。
        static let roleTun = dyn("DS.roleTun", light: srgb(0x0D9E67), dark: srgb(0x19C37D))

        static let roleTailscale = dyn("DS.roleTailscale", light: srgb(0x0D9488), dark: srgb(0x2DD4BF))

        static let roleZerotier = dyn("DS.roleZerotier", light: srgb(0xD97706), dark: srgb(0xF59E0B))

        static let roleOray = dyn("DS.roleOray", light: srgb(0x9333EA), dark: srgb(0xA855F7))

        static let roleOther = dyn("DS.roleOther", light: srgb(0x8E8E93), dark: srgb(0x98989D))

        // MARK: Neutrals

        static let track     = Color.primary.opacity(0.06)
        static let fillFaint = Color.primary.opacity(0.04)
        static let fill      = Color.primary.opacity(0.07)
        static let hairline  = Color.primary.opacity(0.08)

        /// Card / control outline — 原型统一 0.5px 边框，不靠投影建立层次。
        static let border = dyn("DS.border", light: srgb(0x000000, 0.09), dark: srgb(0xFFFFFF, 0.08))

        /// Stronger outline for chips / dashed zones / secondary buttons.
        static let borderStrong = dyn("DS.borderStrong", light: srgb(0x000000, 0.16), dark: srgb(0xFFFFFF, 0.15))

        static let separator = dyn("DS.separator", light: srgb(0x000000, 0.07), dark: srgb(0xFFFFFF, 0.07))

        /// 三级文字 (`--text-faint`) — mono 副标、单位、占位。
        /// `.secondary` 已覆盖二级 (`--text-dim`)。
        static let textFaint = dyn("DS.textFaint", light: srgb(0x000000, 0.32), dark: srgb(0xFFFFFF, 0.32))

        /// 选中段 / 选中 chip 的投影 —— 让当前项从轨道里浮起来。
        /// 这是全 App 唯一使用投影建立层次的地方：卡片一律用 0.5px 边框，
        /// 只有"当前选中"需要在同一平面内额外拉开一层。
        static let selectionShadow = dyn("DS.selectionShadow",
                                         light: srgb(0x000000, 0.28),
                                         dark:  srgb(0x000000, 0.55))

        /// 选中胶囊的顶部高光 / 底部收暗 —— 单靠投影只交代"离开背景"，
        /// 加一道竖直渐变才读出"这是一个有厚度的物体"而不是一块贴纸。
        static let selectionGlossTop = dyn("DS.selectionGlossTop",
                                           light: srgb(0xFFFFFF, 0.35),
                                           dark:  srgb(0xFFFFFF, 0.22))
        static let selectionGlossBottom = dyn("DS.selectionGlossBottom",
                                              light: srgb(0x000000, 0.05),
                                              dark:  srgb(0x000000, 0.12))

        /// 原型统一用 0.5px 边框而非投影 (macOS 惯例)。保留 token 以兼容调用点，
        /// 值为全透明——不要在新代码里依赖它建立层次。
        static let cardShadow = dyn("DS.cardShadow", light: srgb(0x000000, 0), dark: srgb(0x000000, 0))

        static let cardShadowContact = dyn("DS.cardShadowContact", light: srgb(0x000000, 0), dark: srgb(0x000000, 0))

        // MARK: Hue-derived badges
        //
        // 地区徽章 / 协议标签按 hue 动态生成 (原型 `oklch(0.7 0.12–0.15 {hue})`)。
        // 这里用 HSB 近似：同一 hue 在明/暗下分别取不同亮度以保住对比度。

        /// 地区徽章前景色。`hue` 为 0–360 色相角。
        static func regionTint(_ hue: Double) -> Color {
            Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
                let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                return NSColor(hue: CGFloat(hue / 360.0), saturation: dark ? 0.55 : 0.75,
                               brightness: dark ? 0.88 : 0.62, alpha: 1)
            }))
        }

        /// 协议标签前景色 — 比地区徽章更低饱和，避免与延迟色抢注意力。
        static func protoTint(_ hue: Double) -> Color {
            Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
                let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                return NSColor(hue: CGFloat(hue / 360.0), saturation: dark ? 0.22 : 0.30,
                               brightness: dark ? 0.80 : 0.52, alpha: 1)
            }))
        }
    }

    // MARK: Spacing — 8pt grid

    enum Spacing {
        static let xs:   CGFloat = 4
        static let s:    CGFloat = 8
        static let m:    CGFloat = 12
        static let l:    CGFloat = 16
        static let xl:   CGFloat = 20
        static let xxl:  CGFloat = 24
        static let xxxl: CGFloat = 32
    }

    // MARK: Corner radius

    enum Radius {
        /// 徽章 / 地区 chip — 原型 4–5px。
        static let badge:   CGFloat = 5
        static let chip:    CGFloat = 6
        static let control: CGFloat = 7
        static let bar:     CGFloat = 3
        /// 节点卡 / route pill / 图标槽 — 原型 8px。
        static let node:    CGFloat = 8
        static let card:    CGFloat = 10
        static let panel:   CGFloat = 12
        /// 状态胶囊 / 筛选 chip — 原型 20px 近似胶囊。
        static let pill:    CGFloat = 20
    }

    // MARK: Motion
    // Spec: Docs/design.md §10. Deliberately no route / segmented tokens —
    // those stay system-default with no custom spring or large transitions.

    enum Motion {
        /// Button press scale settle.
        static let press = Animation.easeOut(duration: 0.12)
        /// Toast enter / leave.
        static let toast = Animation.spring(duration: 0.3)
        /// Small UI micro-interactions (e.g. proxy group collapse).
        static let micro = Animation.easeInOut(duration: 0.18)
        /// How long a toast stays visible before auto-dismiss.
        static let toastHold: TimeInterval = 2.4

        /// Honor the system "Reduce Motion" accessibility setting: returns `nil`
        /// (no animation — SwiftUI applies the state change instantly) when the
        /// user has asked for reduced motion, otherwise the given animation.
        /// Use at call sites via `.animation(DS.Motion.resolve(.toast, reduce: x), …)`.
        static func resolve(_ animation: Animation?, reduce: Bool) -> Animation? {
            reduce ? nil : animation
        }
    }

    // MARK: Progress
    // Keep ProgressView sizes consistent across chrome (sidebar/menu) and forms.

    enum Progress {
        /// Scale applied on top of `.controlSize(.mini)` for dense chrome rows.
        static let miniScale: CGFloat = 0.7
    }

    // MARK: Icon sizes

    enum Icon {
        static let sm:   CGFloat = 14
        static let md:   CGFloat = 16
        static let lg:   CGFloat = 20
        static let xl:   CGFloat = 28
        static let hero: CGFloat = 48

        /// Prefer this over raw `.font(.system(size: DS.Icon.x))` at call sites.
        static func font(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
            .system(size: size, weight: weight)
        }
    }

    // MARK: Layout constants

    enum Layout {
        static let fieldTrailing: CGFloat = 160
        /// Shared height for text fields, menu pickers, and toolbar buttons.
        /// 原型 `.tbtn` = 28px。
        static let controlHeight: CGFloat = 28
        /// 轨道边缘到选中胶囊的内缩 —— 也是胶囊阴影的可见余量
        /// (inset 太小，胶囊的投影会被轨道的 clipShape 削掉)。
        static let segCapsuleInset: CGFloat = 3
        /// 切换器 / TAB 轨道高度。
        /// 约束不是"比按钮高 2pt"这一个数，而是"选中胶囊本身 ≥ 按钮高度"——
        /// 胶囊可见高度 = segHeight − 2×segCapsuleInset，必须先满足这个，
        /// 轨道自然就比按钮更高。用 controlHeight（而非某个更小的数）做胶囊下限，
        /// 是因为胶囊承载的是可点击的当前状态，不该比普通按钮更矮。
        static let segHeight: CGFloat = controlHeight + 2 * segCapsuleInset
        /// Top chrome band height shared by sidebar header and content toolbars.
        /// `s + controlHeight + s` = 44 — 原型 `.titlebar` 高度。
        static let chromeHeight: CGFloat = Spacing.s + controlHeight + Spacing.s
        /// Horizontal inset shared by toolbar strips, table/list content, and sidebar header/footer.
        static let pageContentInset: CGFloat = 18
        /// 表格行高 — 原型 `--row-h` regular = 30px。
        static let rowHeight:     CGFloat = 30
        static let statHeight:    CGFloat = 64
        /// 卡头定高 — 原型 `.card-head`。锁死后，卡头里放 Seg(28) 还是纯文字图例，
        /// 同一行相邻卡片的分隔线与内容起始位置都在同一条基线上。
        static let cardHeadHeight: CGFloat = 40

        // MARK: 卡片栅格
        //
        // 原型内容区是 12px gutter 的三列栅格，宽卡用 `2fr 1fr` 表达（= 跨 2 列）。
        // 定高卡片只能取下面三档之一 —— 此前散落着 152 / 208 / 232 三个字面量，
        // 同一行相邻卡片取到不同值时高度就对不上。

        /// 内容栅格列间距 / 行间距 — 原型 `gap: 12px`。
        static let gridGutter: CGFloat = Spacing.m
        /// 自适应网格的最小列宽：数值卡 150 / 节点卡 190 / 配置卡 258（原型 minmax）。
        static let gridMinStat: CGFloat = 150
        static let gridMinNode: CGFloat = 190
        static let gridMinProfile: CGFloat = 258

        /// 头部 + 单行控件（代理页 grid 模式的组卡：图标+名称+徽章头 56 左右，
        /// 底下一行选择器/只读行 41 左右）。比 `cardHeightSm` 更紧凑——那个尺寸是
        /// 给仪表盘"当前链路"这类需要留白呼吸的卡片用的，直接搬来给这种头+一行
        /// 控件的卡片会在底部空出一大截，卡片显得没内容。
        static let cardHeightXs: CGFloat = 104

        /// 单行内容（当前链路 / 出口分布）。
        static let cardHeightSm: CGFloat = 152
        /// 排名 / 列表类，容纳 3–4 行。
        static let cardHeightMd: CGFloat = 208
        /// 图表类。
        static let cardHeightLg: CGFloat = 232

        @available(*, deprecated, renamed: "cardHeightMd")
        static let cardRow:       CGFloat = 208
        /// Config profile cards share a fixed min height so active/inactive CTAs don't change size.
        static let profileCardMinHeight: CGFloat = 148
        // MARK: 窗口尺寸
        //
        // 最小宽度由内容区最窄的可用栅格反推，而不是拍脑袋：
        //   仪表盘三列栅格，右列要放下环形图 + 「代理 173.1 MB」图例 ≈ 250
        //   → 内容区 = 3×250 + 2×gutter + 2×pageContentInset ≈ 810
        //   → 窗口 = sidebarMin(208) + 810 ≈ 1020
        // 连接页表格列的 min 合计 ≈ 750，落在这个宽度内。
        /// 主窗口最小宽度 —— 再窄栅格列就会挤到放不下内容。
        static let windowMinWidth:  CGFloat = 1020
        /// 主窗口最小高度 —— 内容纵向可滚动，这里只保证顶栏 + 两行卡片可见。
        static let windowMinHeight: CGFloat = 640
        /// 默认开窗尺寸 —— 一屏放下仪表盘全部四行，无需滚动。
        static let windowIdealWidth:  CGFloat = 1240
        static let windowIdealHeight: CGFloat = 840

        /// Sidebar column width — 原型 220px。
        static let sidebarMin:    CGFloat = 208
        static let sidebarIdeal:  CGFloat = 220
        static let sidebarMax:    CGFloat = 280
        /// Sidebar nav row height — 原型 `.sb-item` = 30px。
        static let sidebarRowHeight: CGFloat = 30
        /// 导航行之间的间隙。行本身是 30pt 的点击靶，紧贴排列时整组会读成一块色块；
        /// 8pt 让每一项各自成立。
        static let sidebarRowGap: CGFloat = Spacing.s
        /// Sidebar nav row vertical inset (each side) — 8pt grid.
        static let sidebarRowVInset: CGFloat = Spacing.xs
        /// Extra gap under app header before the first section ("监控").
        static let sidebarSectionTop: CGFloat = Spacing.m

        // MARK: 图标槽 (原型固定尺寸)

        /// 代理组 / 配置卡图标槽 — 28×28 r8。
        static let iconSlotSm: CGFloat = 28
        /// SD-WAN 接口图标槽 — 38×38 r10。
        static let iconSlotMd: CGFloat = 38
        /// 设置页 switch-hero 图标槽 — 40×40 r11。
        static let iconSlotLg: CGFloat = 40
    }

    // MARK: Shapes

    enum Shape {
        static func badge(_ r: CGFloat = Radius.badge) -> RoundedRectangle {
            RoundedRectangle(cornerRadius: r, style: .continuous)
        }
        static func chip(_ r: CGFloat = Radius.chip) -> RoundedRectangle {
            RoundedRectangle(cornerRadius: r, style: .continuous)
        }
        /// 节点卡 / route pill / 图标槽 / seg 轨道 — radius 8。
        static func node(_ r: CGFloat = Radius.node) -> RoundedRectangle {
            RoundedRectangle(cornerRadius: r, style: .continuous)
        }
        static func control(_ r: CGFloat = Radius.control) -> RoundedRectangle {
            RoundedRectangle(cornerRadius: r, style: .continuous)
        }
        static func card(_ r: CGFloat = Radius.card) -> RoundedRectangle {
            RoundedRectangle(cornerRadius: r, style: .continuous)
        }
        static func panel(_ r: CGFloat = Radius.panel) -> RoundedRectangle {
            RoundedRectangle(cornerRadius: r, style: .continuous)
        }
    }
}

// MARK: - Type scale
//
// 24 stat · 21 page title · 17 section · 14 app name · 13.5 card name · 13 label ·
// 12.5 sidebar name · 12 body · 11 caption · 10 mono tiny / section label · 9.5 badge / micro.

extension Font {
    static let dsPageTitle    = Font.system(size: 21, weight: .bold)
    static let dsSection      = Font.system(size: 17, weight: .semibold)
    /// 组卡 / 接口卡标题 — 原型 13.5px/700。
    static let dsCardName     = Font.system(size: 13.5, weight: .bold)
    static let dsLabel        = Font.system(size: 13)
    static let dsCardLabel    = Font.system(size: 13, weight: .semibold)
    static let dsLabelBold    = Font.system(size: 13, weight: .bold)
    static let dsBody         = Font.system(size: 12)
    static let dsBodyMedium   = Font.system(size: 12, weight: .medium)
    static let dsBodySemibold = Font.system(size: 12, weight: .semibold)
    static let dsBodyBold     = Font.system(size: 12, weight: .bold)
    static let dsMono         = Font.system(size: 12, design: .monospaced)
    static let dsMonoBold     = Font.system(size: 12, weight: .bold, design: .monospaced)
    /// 表格 / 延迟 / 地址等密集数值 — 原型 11–11.5px mono。
    static let dsMonoSm       = Font.system(size: 11, design: .monospaced)
    static let dsMonoSmBold   = Font.system(size: 11, weight: .semibold, design: .monospaced)
    /// stat-sub / 表单 key 提示 — 原型 10–10.5px mono。
    static let dsMonoTiny     = Font.system(size: 10, design: .monospaced)
    /// 地区徽章 / 组类型徽章 — 原型 9.5px/800 mono。
    static let dsBadge        = Font.system(size: 9.5, weight: .heavy, design: .monospaced)
    /// 协议标签 — 原型 10px/700 mono。
    static let dsProtoTag     = Font.system(size: 10, weight: .bold, design: .monospaced)
    /// 大数值 — 原型 24px/700，界面字体 + tabular，不用 rounded。
    static let dsStatValue    = Font.system(size: 24, weight: .bold)
    /// stat-card 标签 — 原型 11px/600。
    static let dsStatLabel    = Font.system(size: 11, weight: .semibold)
    /// 卡头 / 表头 — 原型 10.5–11px/700 uppercase（大写由调用点 `.textCase(.uppercase)`）。
    static let dsCardTitle    = Font.system(size: 11, weight: .bold)
    static let dsTableHeader  = Font.system(size: 10.5, weight: .bold)
    static let dsCaption      = Font.system(size: 11)
    static let dsCaptionBold  = Font.system(size: 11, weight: .semibold)

    // MARK: Shell / 微型标注
    //
    // 以下几档只服务侧栏 shell 与密集标注。补齐前它们是散落的
    // `.font(.system(size:))` 字面量，改一处字号要全局搜索才能对齐。

    /// 侧栏 App 名 — 原型 `.sb-app` 14px/700。
    static let dsAppName      = Font.system(size: 14, weight: .bold)
    /// 侧栏当前出口名 — 比 App 名低一档，仍需压过状态行。
    static let dsSidebarName  = Font.system(size: 12.5, weight: .bold)
    /// 侧栏分组标题（概览 / 代理 / 网络 / 配置）— 原型 10px/600。
    static let dsSectionLabel = Font.system(size: 10, weight: .semibold)
    /// 版本号等次要 mono 标注 — 比 `dsMonoTiny` 再小半档。
    static let dsMonoMicro    = Font.system(size: 9.5, design: .monospaced)
    /// 计数尾注（分组标题右侧的 mono 数字）。
    static let dsCountSm      = Font.system(size: 9.5, weight: .semibold, design: .monospaced)
    /// 彩色小标签文字 — 非 mono，区别于 `dsBadge`。
    static let dsTagSm        = Font.system(size: 9.5, weight: .bold)
    /// 元信息列标签（订阅卡右侧「节点数 / 到期」等）。
    static let dsMetaLabel    = Font.system(size: 9.5)
}

// MARK: - Controls

/// One option shared by the fixed-height segmented and menu controls.
struct DSChoice<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    let systemImage: String?

    init(_ title: String, _ value: Value, systemImage: String? = nil) {
        self.value = value
        self.title = title
        self.systemImage = systemImage
    }

    var id: Value { value }
}

/// Segmented control — 原型 `.seg`：recessed 轨道 (radius 8) + 2px inset，
/// 选中段填 accent、文字 accentInk；段高 24，整体 28。
/// We deliberately do not use AppKit's segmented picker: its visual bezel
/// varies between 24, 28 and 33pt across control sizes.
struct DSSegmentedControl<Value: Hashable>: View {
    @Binding var selection: Value
    let choices: [DSChoice<Value>]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(choices) { choice in
                let selected = selection == choice.value
                Button { selection = choice.value } label: {
                    HStack(spacing: 5) {
                        if let image = choice.systemImage {
                            Image(systemName: image)
                                .font(DS.Icon.font(13, weight: .semibold))
                                .symbolRenderingMode(.monochrome)
                        }
                        if !choice.title.isEmpty {
                            Text(choice.title)
                                .font(.dsCaptionBold)
                                .lineLimit(1)
                        }
                    }
                    .padding(.horizontal, DS.Spacing.m - 1)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .foregroundStyle(selected ? DS.Palette.accentInk : Color.secondary)
                    .background(
                        Group {
                            if selected {
                                DS.Shape.chip().dsElevatedFill(DS.Palette.accent)
                            }
                        }
                    )
                    .overlay(
                        DS.Shape.chip()
                            .strokeBorder(Color.white.opacity(selected ? 0.18 : 0), lineWidth: 0.5)
                    )
                    .contentShape(DS.Shape.chip())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityLabel(choice.title.isEmpty ? (choice.systemImage ?? "") : choice.title)
            }
        }
        .padding(DS.Layout.segCapsuleInset)
        .frame(height: DS.Layout.segHeight)
        .background(DS.Shape.node().fill(DS.Palette.inputBg))
        .overlay(DS.Shape.node().strokeBorder(DS.Palette.border, lineWidth: 0.5))
        .clipShape(DS.Shape.node())
    }
}

/// Fixed 32pt menu selector. A popover list is used instead of SwiftUI `Menu`,
/// whose AppKit button cell adds variable 24–33pt native chrome.
struct DSMenuPicker<Value: Hashable>: View {
    @Binding var selection: Value
    let choices: [DSChoice<Value>]
    @State private var isPresented = false

    private var current: DSChoice<Value>? { choices.first { $0.value == selection } }

    var body: some View {
        Button { isPresented = true } label: {
            HStack(spacing: DS.Spacing.s) {
                if let image = current?.systemImage {
                    Image(systemName: image)
                }
                Text(current?.title ?? "—")
                    .lineLimit(1)
                    // 防止在拥挤的工具栏里被压成 "1…"
                    .fixedSize()
                Spacer(minLength: DS.Spacing.xs)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.dsCaption)
                    .foregroundColor(.secondary)
            }
            .font(.dsBody)
            .padding(.horizontal, DS.Spacing.s)
            .frame(height: DS.Layout.controlHeight, alignment: .center)
            .background(DS.Shape.control().fill(DS.Palette.controlBg))
            .overlay(DS.Shape.control().strokeBorder(DS.Palette.borderStrong, lineWidth: 0.5))
            .contentShape(DS.Shape.control())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                    ForEach(choices) { choice in
                        Button {
                            selection = choice.value
                            isPresented = false
                        } label: {
                            HStack(spacing: DS.Spacing.s) {
                                if let image = choice.systemImage {
                                    Image(systemName: image)
                                        .frame(width: DS.Icon.sm)
                                }
                                Text(choice.title)
                                    .lineLimit(1)
                                Spacer(minLength: DS.Spacing.s)
                                if choice.value == selection {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(DS.Palette.accent)
                                }
                            }
                            .font(.dsBody)
                            .foregroundColor(.primary)
                            .padding(.horizontal, DS.Spacing.s)
                            .frame(height: DS.Layout.controlHeight, alignment: .leading)
                            .contentShape(DS.Shape.control())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(DS.Spacing.s)
            }
            .frame(minWidth: 180, maxWidth: 320, maxHeight: 288)
            .background(DS.Palette.cardBg)
        }
    }
}

/// Visual variants for standard 32pt text actions.
enum DSButtonVariant {
    case secondary
    case prominent
    case warning
    case destructive
    case plain
}

/// Forces icon+title into a single centered HStack. Default `Label` layout on
/// macOS can leave the title optically off-center inside a fixed 32pt chrome
/// (especially with SF Symbols of uneven advance).
private struct DSButtonLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon
                .symbolRenderingMode(.monochrome)
                .font(DS.Icon.font(DS.Icon.sm, weight: .semibold))
            configuration.title
                .lineLimit(1)
        }
    }
}

/// The actual button chrome, not just an outer layout frame.
struct DSButtonStyle: ButtonStyle {
    let variant: DSButtonVariant
    @Environment(\.isEnabled) private var isEnabled

    init(_ variant: DSButtonVariant = .secondary) {
        self.variant = variant
    }

    private var foreground: Color {
        switch variant {
        case .secondary: return .primary
        case .prominent: return DS.Palette.accentInk
        case .warning, .destructive: return .white
        case .plain: return DS.Palette.accentStrong
        }
    }

    private var fill: Color {
        switch variant {
        case .secondary: return DS.Palette.controlBg
        case .prominent: return DS.Palette.accent
        case .warning: return DS.Palette.warn
        case .destructive: return DS.Palette.error
        case .plain: return .clear
        }
    }

    private var stroke: Color {
        variant == .secondary ? DS.Palette.borderStrong : .clear
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(DSButtonLabelStyle())
            .font(.dsCaptionBold)
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, DS.Spacing.s + 2)
            // Center the label group in both axes inside the 28pt chrome; hug
            // content width so toolbar buttons don't stretch after Spacer.
            .frame(height: DS.Layout.controlHeight, alignment: .center)
            .fixedSize(horizontal: true, vertical: false)
            .background(DS.Shape.control().fill(fill))
            .overlay(DS.Shape.control().strokeBorder(stroke, lineWidth: 0.5))
            .clipShape(DS.Shape.control())
            .contentShape(DS.Shape.control())
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(DS.Motion.press, value: configuration.isPressed)
    }
}

// MARK: - Input Styles

struct DSTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .font(.dsBody)
            .padding(.horizontal, DS.Spacing.s)
            .frame(height: DS.Layout.controlHeight)
            .background(DS.Palette.inputBg)
            .clipShape(DS.Shape.control())
            .overlay(DS.Shape.control().strokeBorder(DS.Palette.border, lineWidth: 0.5))
    }
}

extension Shape {
    /// 选中态填充：底色 + 折入同一 shape 的渐变高光（不是 `.overlay()`，避免
    /// 方形渐变在圆角处露出方角）+ 外投影（离开背景）+ 收紧的贴近阴影（边缘厚度）。
    /// 三层叠加才读作"浮起的实体"；只有投影是"贴纸带了点灰影"。
    @ViewBuilder
    func dsElevatedFill(_ color: Color) -> some View {
        ZStack {
            self.fill(color)
            self.fill(
                LinearGradient(colors: [DS.Palette.selectionGlossTop, DS.Palette.selectionGlossBottom],
                               startPoint: .top, endPoint: .bottom)
            )
            .blendMode(.overlay)
        }
        .shadow(color: DS.Palette.selectionShadow, radius: 4, x: 0, y: 1.5)
        .shadow(color: DS.Palette.selectionShadow.opacity(0.5), radius: 1, x: 0, y: 0.5)
    }
}

extension View {
    /// Apply standard input field styling (fixed height, matches menu pickers).
    func inputStyle() -> some View {
        self.textFieldStyle(DSTextFieldStyle())
    }

    /// Dense chrome spinner (sidebar / menu-bar busy rows). Prefer this over
    /// ad-hoc `scaleEffect(0.7)` so all busy indicators match.
    @ViewBuilder
    func dsMiniProgress() -> some View {
        ProgressView()
            .controlSize(.mini)
            .scaleEffect(DS.Progress.miniScale)
    }

    /// Toolbar / filter search field chrome (plain field + control surface).
    /// Fixed to `DS.Layout.controlHeight` to match tabs / buttons / inputs (同 `inputStyle()`)。
    func dsSearchFieldChrome(maxWidth: CGFloat? = 280) -> some View {
        self
            .padding(.horizontal, DS.Spacing.s)
            .frame(height: DS.Layout.controlHeight)
            .frame(maxWidth: maxWidth)
            .background(DS.Shape.control().fill(DS.Palette.inputBg))
            .overlay(DS.Shape.control().strokeBorder(DS.Palette.border, lineWidth: 0.5))
    }

    /// Deprecated: native Picker chrome is not dimensionally stable. Use
    /// `DSMenuPicker` or `DSSegmentedControl` instead.
    @available(*, deprecated, message: "Use DSMenuPicker")
    func dsMenuControl() -> some View { self.frame(height: DS.Layout.controlHeight) }

    /// Deprecated: native Picker chrome is not dimensionally stable. Use
    /// `DSSegmentedControl` instead.
    @available(*, deprecated, message: "Use DSSegmentedControl")
    func dsActionControl() -> some View { self.frame(height: DS.Layout.controlHeight) }

    /// A standard text action with actual 32pt button chrome.
    func dsButton(_ variant: DSButtonVariant = .secondary) -> some View {
        self.buttonStyle(DSButtonStyle(variant))
    }

    /// Toolbar alias for segmented/menu controls. Buttons must use `dsButton()`.
    func dsToolbarControl() -> some View {
        self.dsActionControl()
    }

    /// Top-level card chrome — 原型 `.card`：`--card` 填充 + 0.5px 边框，无投影。
    /// Default radius is `DS.Radius.card` (10). Use for page-grid sibling cards
    /// (`Card`, dashboard stat cards, profile cards). Nested surfaces inside a
    /// card step down to `node` (8) / `control` (7) — see nested-radius cascade.
    func dsCardChrome(radius: CGFloat = DS.Radius.card) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return self
            .background(shape.fill(DS.Palette.cardBg))
            .overlay(shape.strokeBorder(DS.Palette.border, lineWidth: 0.5))
    }

    /// Nested / control-surface chrome at `Radius.control` (7).
    /// For surfaces **inside** a top-level card, chips, or compact control shells.
    /// Do **not** use for page-grid sibling cards (those must use `dsCardChrome`).
    func dsControlChrome(radius: CGFloat = DS.Radius.control) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return self
            .background(shape.fill(DS.Palette.cardBg))
            .overlay(shape.strokeBorder(DS.Palette.border, lineWidth: 0.5))
    }
}

// MARK: - Shared material helper

struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode = .withinWindow
    var state: NSVisualEffectView.State = .active

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blendingMode
        v.state = state
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = state
    }
}

// MARK: - Token gallery

#Preview("Design Tokens") {
    ScrollView {
        VStack(alignment: .leading, spacing: DS.Spacing.l) {
            Group {
                Text("Type scale").font(.dsSection)
                Text("dsPageTitle 22").font(.dsPageTitle)
                Text("dsSection 17").font(.dsSection)
                Text("dsStatValue 20").font(.dsStatValue)
                Text("dsLabel / dsCardLabel 13").font(.dsLabel)
                Text("dsBody 12").font(.dsBody)
                Text("dsCaption 11").font(.dsCaption)
                Text("dsMono 0123456789 ms").font(.dsMono)
            }
            Divider()
            Text("Surfaces").font(.dsSection)
            HStack(spacing: DS.Spacing.s) {
                ForEach(Array([
                    ("window", DS.Palette.windowBg), ("sidebar", DS.Palette.sidebarBg),
                    ("card", DS.Palette.cardBg), ("control", DS.Palette.controlBg),
                    ("chrome", DS.Palette.chromeBg)
                ].enumerated()), id: \.offset) { _, item in
                    swatch(item.0, item.1)
                }
            }
            Text("Status / Traffic").font(.dsSection)
            HStack(spacing: DS.Spacing.s) {
                ForEach(Array([
                    ("accent", DS.Palette.accent), ("ok", DS.Palette.ok),
                    ("warn", DS.Palette.warn), ("error", DS.Palette.error),
                    ("info", DS.Palette.info), ("upload", DS.Palette.upload)
                ].enumerated()), id: \.offset) { _, item in
                    swatch(item.0, item.1)
                }
            }
            Text("Roles").font(.dsSection)
            HStack(spacing: DS.Spacing.s) {
                ForEach(Array([
                    ("phys", DS.Palette.rolePhysical), ("ts", DS.Palette.roleTailscale),
                    ("zt", DS.Palette.roleZerotier), ("oray", DS.Palette.roleOray),
                    ("other", DS.Palette.roleOther)
                ].enumerated()), id: \.offset) { _, item in
                    swatch(item.0, item.1)
                }
            }
            Divider()
            Text("Icons sm/md/lg/xl/hero").font(.dsSection)
            HStack(spacing: DS.Spacing.l) {
                Image(systemName: "bolt.fill").font(DS.Icon.font(DS.Icon.sm))
                Image(systemName: "bolt.fill").font(DS.Icon.font(DS.Icon.md))
                Image(systemName: "bolt.fill").font(DS.Icon.font(DS.Icon.lg))
                Image(systemName: "bolt.fill").font(DS.Icon.font(DS.Icon.xl))
                Image(systemName: "bolt.fill").font(DS.Icon.font(DS.Icon.hero))
            }
        }
        .padding(DS.Spacing.xl)
    }
    .frame(width: 520, height: 680)
    .background(DS.Palette.windowBg)
}

@ViewBuilder
private func swatch(_ name: String, _ color: Color) -> some View {
    VStack(spacing: DS.Spacing.xs) {
        RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
            .fill(color)
            .frame(width: 56, height: 40)
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                    .stroke(DS.Palette.border)
            )
        Text(name).font(.dsMono)
    }
}
