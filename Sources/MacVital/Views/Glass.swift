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
