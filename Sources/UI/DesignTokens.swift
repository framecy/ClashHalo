import SwiftUI

// MARK: - Design Tokens
//
// Single source of truth for the design system: colors, type scale, spacing and
// radii. Use these instead of hardcoded literals so the design language stays
// consistent and theming adapts in one place.
//
// Values are taken from the audited current majority (12pt body, 16 card pad,
// radius 12 card / 8 control, accent + secondary), so adopting them is a no-op
// visually — the goal of this first step is to *centralize*, then migrate
// outlier call sites (hardcoded 0x2A/0x2C bg, 11/13/16pt, padding 18-vs-20) onto
// these tokens incrementally.
//
// NOTE: the dynamic theme/accent color stays in `AppModel.accent` (user-selectable);
// these tokens cover the static parts of the system.

enum DS {

    // MARK: Colors

    enum Palette {
        /// Elevated surface / card background. Replaces the hardcoded
        /// `Color(red: 0x2A…)` literals scattered across 4 files.
        static let cardBg = Color(red: 0x2A / 255.0, green: 0x2A / 255.0, blue: 0x2A / 255.0)
        /// Slightly lighter surface (was `Color(red: 0x2C…)`).
        static let cardBgAlt = Color(red: 0x2C / 255.0, green: 0x2C / 255.0, blue: 0x2C / 255.0)

        /// Semantic status colors — use instead of raw `.green/.red/.orange`.
        static let ok    = Color.green   // running / connected / low latency / success
        static let error = Color.red     // error / upload / high latency / reject
        static let warn  = Color.orange  // warning / medium latency / outdated
        static let info  = Color.cyan    // neutral info / category accent

        /// Hairline separators / subtle fills (was `Color.primary.opacity(0.08)`).
        static let hairline = Color.primary.opacity(0.08)
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
}
