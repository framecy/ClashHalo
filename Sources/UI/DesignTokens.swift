import SwiftUI

// MARK: - Design Tokens
//
// Single source of truth for the design system: colors, type scale, spacing,
// radii, icon sizes and layout constants. Use these instead of hardcoded
// literals so the design language stays consistent and adapts in one place.
//
// Theme: light / dark mode only. A single brand accent color is used throughout;
// there is no user-selectable accent picker.

enum DS {

    // MARK: Colors

    enum Palette {
        /// Brand accent — fixed green, used app-wide for primary interactive elements.
        static let accent = Color(red: 0x19 / 255.0, green: 0xC3 / 255.0, blue: 0x7D / 255.0)

        /// Elevated surface / card background — adapts to light/dark.
        static let cardBg = Color(nsColor: .init(name: nil, dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(red: 0x2A / 255.0, green: 0x2A / 255.0, blue: 0x2A / 255.0, alpha: 1)
                : NSColor.white
        }))
        /// Slightly lighter/darker surface variant.
        static let cardBgAlt = Color(nsColor: .init(name: nil, dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(red: 0x2C / 255.0, green: 0x2C / 255.0, blue: 0x2C / 255.0, alpha: 1)
                : NSColor(red: 0xEE / 255.0, green: 0xEE / 255.0, blue: 0xEE / 255.0, alpha: 1)
        }))
        /// Root window/content area background.
        static let windowBg = Color(nsColor: .init(name: nil, dynamicProvider: { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(red: 0x1E / 255.0, green: 0x1E / 255.0, blue: 0x1E / 255.0, alpha: 1)
                : NSColor(red: 0xF5 / 255.0, green: 0xF5 / 255.0, blue: 0xF7 / 255.0, alpha: 1)
        }))

        /// Semantic status colors — use instead of raw `.green/.red/.orange`.
        static let ok    = Color.green   // running / connected / low latency / success
        static let error = Color.red     // error / upload / high latency / reject
        static let warn  = Color.orange  // warning / medium latency / outdated
        static let info  = Color.cyan    // neutral info / category accent

        /// Neutral fills & borders — semantic opacity ramp over `Color.primary`,
        /// replacing the scattered `primary.opacity(0.03…0.12)` literals.
        static let track    = Color.primary.opacity(0.03)  // progress / bar tracks
        static let fillFaint = Color.primary.opacity(0.04) // faint chip fill
        static let fill     = Color.primary.opacity(0.06)  // subtle active fill
        static let hairline = Color.primary.opacity(0.08)  // separators / chip fill
        static let border   = Color.primary.opacity(0.12)  // visible hairline border
    }

    // MARK: Spacing — 8pt grid (with 4 as the micro step)

    enum Spacing {
        static let xs:  CGFloat = 4
        static let s:   CGFloat = 8
        static let m:   CGFloat = 12
        static let l:   CGFloat = 16   // card inner padding (matches Card)
        static let xl:  CGFloat = 20   // page content padding (standard)
        static let xxl: CGFloat = 24
    }

    // MARK: Corner radius

    enum Radius {
        static let card:    CGFloat = 12
        static let control: CGFloat = 8
    }

    // MARK: Icon sizes (SF Symbols) — separate from the text type scale.
    // Icons legitimately need their own sizes; outlier glyph sizes (15/16/34/60)
    // were snapped to the nearest step here so icon sizing is consistent too.

    enum Icon {
        static let sm:   CGFloat = 16   // was 15/16 (logo bolt, inline glyphs)
        static let md:   CGFloat = 20   // toolbar / stat icons
        static let lg:   CGFloat = 24
        static let xl:   CGFloat = 32   // was 34 (empty-state)
        static let hero: CGFloat = 56   // was 60 (about splash)
    }

    // MARK: Layout — recurring fixed dimensions (form controls, stat cards).

    enum Layout {
        static let fieldTrailing: CGFloat = 160   // trailing control column in form rows
        static let statHeight:    CGFloat = 64    // dashboard stat bar / mini-stat height
        static let cardRow:       CGFloat = 208   // dashboard equal-height card row
    }
}

// MARK: - Type scale
//
// 24 page title · 20 section · 14 emphasis · 12 body (baseline) · 12 mono · 20 stat.
// Former outlier sizes (10/18/22) have been snapped onto these steps; icon glyph
// sizes live separately in DS.Icon.

extension Font {
    static let dsPageTitle    = Font.system(size: 24, weight: .bold)        // PageHead title
    static let dsSection      = Font.system(size: 20, weight: .bold)        // section heading
    // 14 — emphasis step (regular / semibold / bold weight variants).
    static let dsLabel        = Font.system(size: 14)
    static let dsCardLabel    = Font.system(size: 14, weight: .semibold)    // card / emphasis
    static let dsLabelBold    = Font.system(size: 14, weight: .bold)
    // 12 — baseline body step (regular / medium / semibold / bold + mono).
    static let dsBody         = Font.system(size: 12)                       // baseline body / label
    static let dsBodyMedium   = Font.system(size: 12, weight: .medium)
    static let dsBodySemibold = Font.system(size: 12, weight: .semibold)
    static let dsBodyBold     = Font.system(size: 12, weight: .bold)
    static let dsMono         = Font.system(size: 12, design: .monospaced)  // numbers / latency / ports
    static let dsMonoBold     = Font.system(size: 12, weight: .bold, design: .monospaced)
    // Display — dashboard hero stat numbers (was an inconsistent 18 / 22; unified
    // onto the 20 step, rounded for the numeric look).
    static let dsStatValue    = Font.system(size: 20, weight: .bold, design: .rounded)
    // 10 — caption for version numbers and small secondary text
    static let dsCaption      = Font.system(size: 10)
}

// MARK: - Input Styles

struct DSTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.plain)
            .font(.dsBody)
            .padding(.horizontal, DS.Spacing.m)
            .padding(.vertical, DS.Spacing.s)
            .background(DS.Palette.cardBg)
            .cornerRadius(DS.Radius.control)
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.control)
                    .stroke(DS.Palette.border, lineWidth: 1)
            )
    }
}

extension View {
    /// Apply standard input field styling
    func inputStyle() -> some View {
        self.textFieldStyle(DSTextFieldStyle())
    }
}

// MARK: - Token gallery (visual self-check)
//
// A single canvas that renders every token. Open in Xcode Previews to eyeball the
// design system in one place and catch drift — the lightweight stand-in for full
// snapshot tests (which need a dedicated XCTest target; see ARCHITECTURE.md).

#Preview("Design Tokens") {
    ScrollView {
        VStack(alignment: .leading, spacing: DS.Spacing.l) {
            Group {
                Text("Type scale").font(.dsSection)
                Text("dsPageTitle 24").font(.dsPageTitle)
                Text("dsSection 20").font(.dsSection)
                Text("dsStatValue 20").font(.dsStatValue)
                Text("dsLabelBold / dsCardLabel / dsLabel 14").font(.dsLabel)
                Text("dsBody / Medium / Semibold / Bold 12").font(.dsBody)
                Text("dsMono 0123456789 ms").font(.dsMono)
            }
            Divider()
            Text("Palette").font(.dsSection)
            HStack(spacing: DS.Spacing.s) {
                ForEach(Array([
                    ("cardBg", DS.Palette.cardBg), ("cardBgAlt", DS.Palette.cardBgAlt),
                    ("ok", DS.Palette.ok), ("warn", DS.Palette.warn),
                    ("error", DS.Palette.error), ("info", DS.Palette.info)
                ].enumerated()), id: \.offset) { _, item in
                    VStack(spacing: DS.Spacing.xs) {
                        RoundedRectangle(cornerRadius: DS.Radius.control)
                            .fill(item.1).frame(width: 56, height: 40)
                            .overlay(RoundedRectangle(cornerRadius: DS.Radius.control).stroke(DS.Palette.border))
                        Text(item.0).font(.dsMono)
                    }
                }
            }
            Divider()
            Text("Icons (sm/md/lg/xl/hero)").font(.dsSection)
            HStack(spacing: DS.Spacing.l) {
                Image(systemName: "bolt.fill").font(.system(size: DS.Icon.sm))
                Image(systemName: "bolt.fill").font(.system(size: DS.Icon.md))
                Image(systemName: "bolt.fill").font(.system(size: DS.Icon.lg))
                Image(systemName: "bolt.fill").font(.system(size: DS.Icon.xl))
                Image(systemName: "bolt.fill").font(.system(size: DS.Icon.hero))
            }
        }
        .padding(DS.Spacing.xl)
    }
    .frame(width: 460, height: 620)
    .background(DS.Palette.cardBg)
}
