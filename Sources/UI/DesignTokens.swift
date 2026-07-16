import SwiftUI
import AppKit

// MARK: - Design Tokens
//
// Single source of truth for the ClashHalo design system.
// Spec: Docs/design.md
// Theme: system Light / Dark via dynamic NSColor providers. No page-level scheme lock.
// Brand: single Halo Green accent.

enum DS {

    // MARK: Colors

    enum Palette {
        // MARK: Brand

        /// Brand accent — Halo Green. Primary actions, selection, TUN-on.
        static let accent = Color(nsColor: .init(name: "DS.accent", dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0x2A / 255.0, green: 0xD0 / 255.0, blue: 0x8A / 255.0, alpha: 1)
                : NSColor(srgbRed: 0x16 / 255.0, green: 0xB3 / 255.0, blue: 0x72 / 255.0, alpha: 1)
        }))

        /// Selected list / chip fill over accent.
        static let accentSoft = Color(nsColor: .init(name: "DS.accentSoft", dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0x2A / 255.0, green: 0xD0 / 255.0, blue: 0x8A / 255.0, alpha: 0.18)
                : NSColor(srgbRed: 0x16 / 255.0, green: 0xB3 / 255.0, blue: 0x72 / 255.0, alpha: 0.14)
        }))

        /// Strong accent for emphasis strokes / text on light fills.
        static let accentStrong = Color(nsColor: .init(name: "DS.accentStrong", dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0x5A / 255.0, green: 0xE0 / 255.0, blue: 0xA8 / 255.0, alpha: 1)
                : NSColor(srgbRed: 0x0E / 255.0, green: 0x8F / 255.0, blue: 0x5B / 255.0, alpha: 1)
        }))

        // MARK: Surfaces (L0–L3 + overlay)

        /// L0 — main content window background.
        static let windowBg = Color(nsColor: .init(name: "DS.windowBg", dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0x1C / 255.0, green: 0x1C / 255.0, blue: 0x1E / 255.0, alpha: 1)
                : NSColor(srgbRed: 0xF2 / 255.0, green: 0xF2 / 255.0, blue: 0xF7 / 255.0, alpha: 1)
        }))

        /// L1 — sidebar background (may sit under vibrancy).
        static let sidebarBg = Color(nsColor: .init(name: "DS.sidebarBg", dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0x24 / 255.0, green: 0x24 / 255.0, blue: 0x26 / 255.0, alpha: 1)
                : NSColor(srgbRed: 0xEB / 255.0, green: 0xEB / 255.0, blue: 0xF0 / 255.0, alpha: 1)
        }))

        /// L2 — elevated card / panel surface.
        static let cardBg = Color(nsColor: .init(name: "DS.cardBg", dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0x2C / 255.0, green: 0x2C / 255.0, blue: 0x2E / 255.0, alpha: 1)
                : NSColor.white
        }))

        /// Slightly differentiated surface (legacy alias kept for gradual migration).
        static let cardBgAlt = Color(nsColor: .init(name: "DS.cardBgAlt", dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0x3A / 255.0, green: 0x3A / 255.0, blue: 0x3C / 255.0, alpha: 1)
                : NSColor(srgbRed: 0xE5 / 255.0, green: 0xE5 / 255.0, blue: 0xEA / 255.0, alpha: 1)
        }))

        /// L3 — control / chip / selected strip fill.
        static let controlBg = Color(nsColor: .init(name: "DS.controlBg", dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0x3A / 255.0, green: 0x3A / 255.0, blue: 0x3C / 255.0, alpha: 1)
                : NSColor(srgbRed: 0xE8 / 255.0, green: 0xE8 / 255.0, blue: 0xED / 255.0, alpha: 1)
        }))

        /// Toolbar strip / chrome band behind filters.
        static let chromeBg = Color(nsColor: .init(name: "DS.chromeBg", dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0x22 / 255.0, green: 0x22 / 255.0, blue: 0x24 / 255.0, alpha: 0.92)
                : NSColor(srgbRed: 0xF7 / 255.0, green: 0xF7 / 255.0, blue: 0xFA / 255.0, alpha: 0.92)
        }))

        /// Overlay / toast material base (usually paired with ultraThinMaterial).
        static let overlayBg = Color(nsColor: .init(name: "DS.overlayBg", dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0x2C / 255.0, green: 0x2C / 255.0, blue: 0x2E / 255.0, alpha: 0.88)
                : NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.88)
        }))

        // MARK: Status

        static let ok = Color(nsColor: .init(name: "DS.ok", dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0x32 / 255.0, green: 0xD7 / 255.0, blue: 0x4B / 255.0, alpha: 1)
                : NSColor(srgbRed: 0x28 / 255.0, green: 0xC8 / 255.0, blue: 0x40 / 255.0, alpha: 1)
        }))

        static let warn = Color(nsColor: .init(name: "DS.warn", dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0xFF / 255.0, green: 0xD6 / 255.0, blue: 0x0A / 255.0, alpha: 1)
                : NSColor(srgbRed: 0xE6 / 255.0, green: 0xA0 / 255.0, blue: 0x00 / 255.0, alpha: 1)
        }))

        static let error = Color(nsColor: .init(name: "DS.error", dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0xFF / 255.0, green: 0x45 / 255.0, blue: 0x3A / 255.0, alpha: 1)
                : NSColor(srgbRed: 0xE0 / 255.0, green: 0x35 / 255.0, blue: 0x2B / 255.0, alpha: 1)
        }))

        static let info = Color(nsColor: .init(name: "DS.info", dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0x64 / 255.0, green: 0xD2 / 255.0, blue: 0xFF / 255.0, alpha: 1)
                : NSColor(srgbRed: 0x00 / 255.0, green: 0x7A / 255.0, blue: 0xFF / 255.0, alpha: 1)
        }))

        /// Upload traffic series / labels.
        static let upload = Color(nsColor: .init(name: "DS.upload", dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0xFF / 255.0, green: 0x6B / 255.0, blue: 0x6B / 255.0, alpha: 1)
                : NSColor(srgbRed: 0xE0 / 255.0, green: 0x45 / 255.0, blue: 0x45 / 255.0, alpha: 1)
        }))

        /// Download traffic series / labels.
        static let download = Color(nsColor: .init(name: "DS.download", dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0x30 / 255.0, green: 0xD1 / 255.0, blue: 0x98 / 255.0, alpha: 1)
                : NSColor(srgbRed: 0x16 / 255.0, green: 0xB3 / 255.0, blue: 0x72 / 255.0, alpha: 1)
        }))

        // MARK: Network role colors (拓扑)

        static let rolePhysical = Color(nsColor: .init(name: "DS.rolePhysical", dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0x5A / 255.0, green: 0xC8 / 255.0, blue: 0xFA / 255.0, alpha: 1)
                : NSColor(srgbRed: 0x00 / 255.0, green: 0x7A / 255.0, blue: 0xFF / 255.0, alpha: 1)
        }))

        static let roleTailscale = Color(nsColor: .init(name: "DS.roleTailscale", dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0x64 / 255.0, green: 0xD2 / 255.0, blue: 0xFF / 255.0, alpha: 1)
                : NSColor(srgbRed: 0x0A / 255.0, green: 0x84 / 255.0, blue: 0xFF / 255.0, alpha: 1)
        }))

        static let roleZerotier = Color(nsColor: .init(name: "DS.roleZerotier", dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0xFF / 255.0, green: 0x9F / 255.0, blue: 0x0A / 255.0, alpha: 1)
                : NSColor(srgbRed: 0xF5 / 255.0, green: 0x8B / 255.0, blue: 0x00 / 255.0, alpha: 1)
        }))

        static let roleOray = Color(nsColor: .init(name: "DS.roleOray", dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0xBF / 255.0, green: 0x5A / 255.0, blue: 0xF2 / 255.0, alpha: 1)
                : NSColor(srgbRed: 0xAF / 255.0, green: 0x52 / 255.0, blue: 0xDE / 255.0, alpha: 1)
        }))

        static let roleOther = Color(nsColor: .init(name: "DS.roleOther", dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0x98 / 255.0, green: 0x98 / 255.0, blue: 0x9D / 255.0, alpha: 1)
                : NSColor(srgbRed: 0x8E / 255.0, green: 0x8E / 255.0, blue: 0x93 / 255.0, alpha: 1)
        }))

        // MARK: Neutrals

        static let track     = Color.primary.opacity(0.06)
        static let fillFaint = Color.primary.opacity(0.04)
        static let fill      = Color.primary.opacity(0.07)
        static let hairline  = Color.primary.opacity(0.08)
        static let border = Color(nsColor: .init(name: "DS.border", dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.10)
                : NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.10)
        }))
        static let separator = Color(nsColor: .init(name: "DS.separator", dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.08)
                : NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.08)
        }))

        /// Soft card shadow — light only; dark relies on surface lift.
        static let cardShadow = Color(nsColor: .init(name: "DS.cardShadow", dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0)
                : NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.06)
        }))
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
        static let chip:    CGFloat = 6
        static let control: CGFloat = 6
        static let bar:     CGFloat = 3
        static let card:    CGFloat = 10
        static let panel:   CGFloat = 12
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
        /// Shared height for text fields, menu pickers, tabs, and toolbar controls.
        static let controlHeight: CGFloat = 32
        /// Horizontal inset shared by toolbar strips and table/list content.
        static let pageContentInset: CGFloat = Spacing.xl
        static let statHeight:    CGFloat = 64
        static let cardRow:       CGFloat = 208
        static let sidebarMin:    CGFloat = 200
        static let sidebarIdeal:  CGFloat = 220
        static let sidebarMax:    CGFloat = 260
    }

    // MARK: Shapes

    enum Shape {
        static func chip(_ r: CGFloat = Radius.chip) -> RoundedRectangle {
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
// 22 page title · 17 section · 13 label · 12 body · 11 caption · 20 stat.

extension Font {
    static let dsPageTitle    = Font.system(size: 22, weight: .bold)
    static let dsSection      = Font.system(size: 17, weight: .semibold)
    static let dsLabel        = Font.system(size: 13)
    static let dsCardLabel    = Font.system(size: 13, weight: .semibold)
    static let dsLabelBold    = Font.system(size: 13, weight: .bold)
    static let dsBody         = Font.system(size: 12)
    static let dsBodyMedium   = Font.system(size: 12, weight: .medium)
    static let dsBodySemibold = Font.system(size: 12, weight: .semibold)
    static let dsBodyBold     = Font.system(size: 12, weight: .bold)
    static let dsMono         = Font.system(size: 12, design: .monospaced)
    static let dsMonoBold     = Font.system(size: 12, weight: .bold, design: .monospaced)
    static let dsStatValue    = Font.system(size: 20, weight: .bold, design: .rounded)
    static let dsCaption      = Font.system(size: 11)
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

/// Fixed 32pt segmented control. We deliberately do not use AppKit's segmented
/// picker: its visual bezel varies between 24, 28 and 33pt across control sizes.
struct DSSegmentedControl<Value: Hashable>: View {
    @Binding var selection: Value
    let choices: [DSChoice<Value>]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(choices) { choice in
                let selected = selection == choice.value
                Button { selection = choice.value } label: {
                    Group {
                        if let image = choice.systemImage {
                            Label(choice.title, systemImage: image)
                        } else {
                            Text(choice.title)
                        }
                    }
                    .font(.dsBodyMedium)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .foregroundColor(selected ? .white : .primary)
                    .background(DS.Shape.control().fill(selected ? DS.Palette.accent : .clear))
                    .contentShape(DS.Shape.control())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .frame(height: DS.Layout.controlHeight)
        .background(DS.Shape.control().fill(DS.Palette.controlBg))
        .overlay(DS.Shape.control().stroke(DS.Palette.border, lineWidth: 1))
        .clipShape(DS.Shape.control())
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
                Spacer(minLength: DS.Spacing.s)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.dsCaption)
                    .foregroundColor(.secondary)
            }
            .font(.dsBody)
            .padding(.horizontal, DS.Spacing.s)
            .frame(height: DS.Layout.controlHeight, alignment: .center)
            .background(DS.Shape.control().fill(DS.Palette.controlBg))
            .overlay(DS.Shape.control().stroke(DS.Palette.border, lineWidth: 1))
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
        case .prominent, .warning, .destructive: return .white
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
        variant == .secondary ? DS.Palette.border : .clear
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.dsBodyMedium)
            .lineLimit(1)
            .foregroundColor(foreground)
            .padding(.horizontal, DS.Spacing.m)
            .frame(height: DS.Layout.controlHeight, alignment: .center)
            .background(DS.Shape.control().fill(fill))
            .overlay(DS.Shape.control().stroke(stroke, lineWidth: 1))
            .clipShape(DS.Shape.control())
            .opacity(isEnabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
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
            .background(DS.Palette.controlBg)
            .clipShape(DS.Shape.control())
            .overlay(DS.Shape.control().stroke(DS.Palette.border, lineWidth: 1))
    }
}

extension View {
    /// Apply standard input field styling (fixed height, matches menu pickers).
    func inputStyle() -> some View {
        self.textFieldStyle(DSTextFieldStyle())
    }

    /// Toolbar / filter search field chrome (plain field + control surface).
    /// Fixed to `DS.Layout.controlHeight` (32) to match tabs / buttons / inputs.
    func dsSearchFieldChrome(maxWidth: CGFloat? = 280) -> some View {
        self
            .padding(.horizontal, DS.Spacing.s)
            .frame(height: DS.Layout.controlHeight)
            .frame(maxWidth: maxWidth)
            .background(DS.Shape.control().fill(DS.Palette.controlBg))
            .overlay(DS.Shape.control().stroke(DS.Palette.border, lineWidth: 1))
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

    /// Continuous card chrome: fill + border + light-only soft shadow.
    func dsCardChrome(radius: CGFloat = DS.Radius.card) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return self
            .background(shape.fill(DS.Palette.cardBg))
            .overlay(shape.stroke(DS.Palette.border, lineWidth: 1))
            .shadow(color: DS.Palette.cardShadow, radius: 8, x: 0, y: 2)
    }

    /// Continuous control chrome.
    func dsControlChrome(radius: CGFloat = DS.Radius.control) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return self
            .background(shape.fill(DS.Palette.cardBg))
            .overlay(shape.stroke(DS.Palette.border, lineWidth: 1))
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
