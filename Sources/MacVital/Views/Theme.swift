import SwiftUI
import AppKit

/// Design tokens, expressed in the system's own vocabulary.
///
/// This used to be the Tidy spec transcribed into fixed hex pairs — a hand
/// approximation of `labelColor`, `separatorColor`, `windowBackgroundColor` and
/// the rest. The approximations were close, and closeness was the problem: a
/// hex value does not know about Increase Contrast, Reduce Transparency,
/// vibrancy on a material, or the accent colour the user picked. The system
/// colours do, and they are what every Apple app is drawn with.
///
/// The names stay so the call sites did not have to change. What they resolve
/// to is the part that moved.
enum Theme {

    // MARK: - Brand

    /// The accent colour — buttons, selection, progress.
    ///
    /// The brand blue now lives in the `AccentColor` asset rather than here.
    /// That is the channel macOS gives an app for this: users on "Multicolor"
    /// see the brand, users who chose an accent in System Settings see theirs.
    /// A hardcoded hex ignored that choice in this app alone.
    static let accent = Color.accentColor
    /// Reclaimable space — the number the user is here to reduce.
    static let junk = Color.orange
    /// Free space, success.
    static let success = Color.green

    // MARK: - Surfaces

    /// Window background.
    static let canvas = Color(nsColor: .windowBackgroundColor)
    /// Content surfaces.
    static let surface = Color(nsColor: .controlBackgroundColor)
    /// A recessed fill inside a surface — stat tiles, chips, icon tiles.
    ///
    /// A system fill rather than a flat colour: it is translucent, so it reads
    /// correctly on whatever it sits on, and it strengthens under Increase
    /// Contrast. The dark-mode separation problem the old hex pair needed a
    /// hand-tuned step for is what the fill colours are designed around.
    static let well = Color(nsColor: .tertiarySystemFill)

    // MARK: - Text

    static let label = Color(nsColor: .labelColor)
    static let secondaryLabel = Color(nsColor: .secondaryLabelColor)
    static let tertiaryLabel = Color(nsColor: .tertiaryLabelColor)

    // MARK: - Lines

    static let separator = Color(nsColor: .separatorColor)
    static let strongSeparator = Color(nsColor: .gridColor)

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
        static let sidebarWidth: CGFloat = 224
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

/// Reusable label for card groups. The icon gives dense pages a stable visual
/// landmark without turning every section into another oversized heading.
struct SectionTitle: View {
    let title: String
    let systemImage: String
    var tint: Color = Theme.accent

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text(title)
                .font(.system(size: Theme.Text.body, weight: .medium))
                .foregroundStyle(Theme.label)
        }
    }
}
