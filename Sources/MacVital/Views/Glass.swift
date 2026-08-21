import SwiftUI

/// Glass surfaces.
///
/// The deployment target is macOS 14, so `glassEffect` cannot simply be called:
/// it arrived in macOS 26. Everything goes through these helpers, which use the
/// real Liquid Glass where it exists and fall back to a `Material` blur that
/// reads the same way on older systems. The fallback is not a stub — a material
/// over a tinted surface is what glass looked like before the API existed.
extension View {

    /// A raised panel: cards, palettes, footers.
    @ViewBuilder
    func glassPanel(cornerRadius: CGFloat = Theme.Radius.card, tinted: Color? = nil) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            self.glassEffect(
                tinted.map { .regular.tint($0.opacity(0.16)) } ?? .regular,
                in: shape
            )
        } else {
            self
                .background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(Theme.separator, lineWidth: 1))
        }
    }

    /// A recessed well inside a panel: stat tiles, search fields, list wells.
    /// Deliberately not glass — stacking glass on glass turns to mud.
    func well(cornerRadius: CGFloat = Theme.Radius.tile) -> some View {
        background(
            Theme.well,
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
    }

    /// Full-bleed chrome: the sidebar and page footers, which sit against the
    /// window edge and want the background to show through.
    @ViewBuilder
    func glassChrome() -> some View {
        if #available(macOS 26.0, *) {
            self.background(.ultraThinMaterial)
        } else {
            self.background(Theme.canvas)
        }
    }
}

/// Something for the glass to bend.
///
/// `glassEffect` refracts and blurs whatever is behind it. Behind every card in
/// this app was one flat opaque colour, so the real Liquid Glass on macOS 26
/// and the `Material` fallback below it rendered as the same thing: a rectangle
/// a shade lighter than the background. The API was wired correctly and doing
/// nothing visible, which reads as the app being flat rather than as glass
/// being off.
///
/// So the content pane gets a gradient instead of a colour — three very soft,
/// very low-opacity pools of the brand colours, bled off the edges. Far too
/// faint to read as decoration on its own (that is the point; this is a tool
/// that displays file paths and sizes, and busy backgrounds behind small text
/// are how those become hard to read), but enough of a luminance ramp that a
/// glass surface crossing it visibly bends something.
///
/// The alternative is letting the desktop through — `isOpaque = false` and a
/// vibrancy backdrop, which is what the system apps do. That is the dramatic
/// version, and it puts the user's wallpaper behind every path string in the
/// app. Not the right trade here.
struct GlassBackdrop: View {
    var body: some View {
        // A `ZStack` over an explicit opaque `Rectangle`, not a `Color` with
        // overlays hung off it. The overlay form was clipped away in some
        // layouts and left the pane painting nothing at all — and a window with
        // no opaque background is a transparent one, so the desktop came
        // through behind every label in the app. Being explicit about the base
        // costs one view and removes the whole failure mode.
        ZStack {
            Rectangle().fill(Theme.surface)

            // A luminance ramp, top to bottom. This is the part that does the
            // work: glass reads as glass when what is behind it changes
            // brightness across the width of a panel, and a ramp does that
            // without introducing a colour of its own.
            LinearGradient(
                colors: [
                    Color.white.opacity(0.05),
                    Color.white.opacity(0),
                    Color.black.opacity(0.06),
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            // One pool, one hue, low. Three hues at high opacity was the first
            // attempt: the corners went orange, blue and green and the middle
            // went the colour of all three mixed. It read as a dirty window
            // rather than as atmosphere.
            pool(Theme.accent, size: 760, opacity: 0.11)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .offset(x: 240, y: -280)
        }
        .compositingGroup()
        .clipped()
        .allowsHitTesting(false)
    }

    private func pool(_ color: Color, size: CGFloat, opacity: Double) -> some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [color.opacity(opacity), color.opacity(0)],
                    center: .center,
                    startRadius: 0,
                    endRadius: size / 2
                )
            )
            .frame(width: size, height: size)
            .blur(radius: 40)
    }
}

/// A card, restyled onto glass. Same name and shape as before so every call
/// site picked up the new look without edits.
struct Card<Content: View>: View {
    var padding: CGFloat = Theme.Metric.cardPadding
    var cornerRadius: CGFloat = Theme.Radius.card
    var tint: Color?
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .glassPanel(cornerRadius: cornerRadius, tinted: tint)
    }
}

/// Groups adjacent glass elements so the system can merge them into one
/// surface instead of rendering separate overlapping sheets. No-op below 26.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}
