import SwiftUI
import AppKit

/// Design tokens from the Tidy spec.
///
/// The spec is written in light mode with fixed hex values. Every token here is
/// declared as a light/dark pair instead: the spec's value is the light side,
/// and the dark side is derived to keep the same contrast relationships. That
/// way the design lands as drawn without giving up the appearance setting.
enum Theme {

    // MARK: - Brand

    /// #378ADD — primary. Buttons, active nav, progress.
    static let accent = Color(hex: 0x378ADD)
    /// #D85A30 — junk / reclaimable. The number the user is here to reduce.
    static let junk = Color(hex: 0xD85A30)
    /// #1D9E75 — free space, success.
    static let success = Color(hex: 0x1D9E75)

    // MARK: - Surfaces

    /// Window background and sidebar.
    static let canvas = adaptive(light: 0xF5F5F7, dark: 0x1C1C1E)
    /// Cards and the content pane.
    static let surface = adaptive(light: 0xFFFFFF, dark: 0x252528)
    /// Inset wells inside a card (stat tiles, search fields).
    static let well = adaptive(light: 0xF5F5F7, dark: 0x2E2E32)

    // MARK: - Text

    static let label = adaptive(light: 0x1D1D1F, dark: 0xF2F2F5)
    static let secondaryLabel = adaptive(light: 0x8E8E93, dark: 0x98989F)
    static let tertiaryLabel = adaptive(light: 0xAEAEB2, dark: 0x7A7A80)

    // MARK: - Lines

    /// The spec's 0.5–1px hairlines. No heavy shadows anywhere.
    static var separator: Color {
        Color.adaptive(
            light: Color.black.opacity(0.08),
            dark: Color.white.opacity(0.10)
        )
    }
    static var strongSeparator: Color {
        Color.adaptive(
            light: Color.black.opacity(0.14),
            dark: Color.white.opacity(0.16)
        )
    }

    // MARK: - Geometry

    /// Glass wants larger radii than flat cards — a tight corner makes the
    /// refraction read as a hard edge instead of a lens.
    enum Radius {
        static let card: CGFloat = 16
        static let tile: CGFloat = 11
        static let chip: CGFloat = 8
        static let control: CGFloat = 9
    }

    /// Type scale. The spec's numbers were drawn for a 660pt mock; at real
    /// window size they read small, so the whole ramp moved up one step.
    /// Sizes live here rather than as literals at call sites — a scale you can
    /// shift in one place is the only kind that stays consistent.
    enum Text {
        /// Page titles.
        static let title: CGFloat = 23
        /// Big numbers: storage ring, reclaimable total.
        static let display: CGFloat = 26
        /// Section headings, card titles, list primary text.
        static let heading: CGFloat = 16
        /// Body and most controls.
        static let body: CGFloat = 14
        /// Secondary lines under a title.
        static let caption: CGFloat = 13
        /// Badges, chips, path monospace.
        static let footnote: CGFloat = 12
        /// The smallest thing that should ever ship — labels on stat tiles.
        static let micro: CGFloat = 11
    }

    /// Spacing scale. Everything got a step wider than the first pass: the
    /// complaint was that the UI felt cramped, and the fix for cramped is
    /// whitespace, not smaller type.
    enum Metric {
        static let sidebarWidth: CGFloat = 208
        static let pagePaddingH: CGFloat = 36
        static let pagePaddingV: CGFloat = 32
        /// Between major blocks on a page.
        static let sectionSpacing: CGFloat = 30
        /// Between cards in a grid.
        static let gridSpacing: CGFloat = 14
        static let cardPadding: CGFloat = 20
        /// Footers and headers that sit against a divider.
        static let barPaddingV: CGFloat = 16
    }

    // MARK: - Helpers

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color.adaptive(light: Color(hex: light), dark: Color(hex: dark))
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }

    /// Resolves per appearance at draw time, so a single token works in both
    /// modes without threading `@Environment(\.colorScheme)` through every view.
    static func adaptive(light: Color, dark: Color) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(isDark ? dark : light)
        })
    }
}

// MARK: - Reusable pieces

/// The ring used for storage and for the junk total. Value is 0...1.
struct ProgressRing<Center: View>: View {
    let value: Double
    var lineWidth: CGFloat = 9
    var tint: Color = Theme.accent
    @ViewBuilder var center: Center

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.separator, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(min(value, 1), 0.004))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.45), value: value)
            center
        }
    }
}

/// Small square glyph tile — the spec puts one in front of every list row and
/// quick action.
struct GlyphTile: View {
    let systemImage: String
    let tint: Color
    var size: CGFloat = 32

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.46, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: size * 0.25, style: .continuous))
    }
}
