import SwiftUI

/// Surfaces, sorted by which layer of the window they belong to.
///
/// Apple's Liquid Glass guidance draws one line and this file follows it:
/// glass is for the **navigation layer** — controls that float above content,
/// like toolbars, sidebars and palettes — and **not for the content layer**.
/// Glass on content competes with the content for attention and, stacked, turns
/// to mud.
///
/// The first version of this app put glass on every card on the page. It was
/// wired correctly and the result still read as flat, because glass with
/// nothing interesting behind it is just a lighter rectangle — so a gradient
/// backdrop was added purely to give the cards something to refract. That was
/// solving the wrong problem. In a `NavigationSplitView` with a real toolbar,
/// the system already puts glass where it belongs; content gets ordinary,
/// calm surfaces, which is what every Apple app does.
extension View {

    /// A content card: grouped information or an action tile on a page.
    ///
    /// A system fill with a hairline, not glass. The fill is translucent, so it
    /// reads correctly in light and dark and on whatever sits behind it, and it
    /// strengthens under Increase Contrast. This is the container treatment
    /// macOS 14 introduced the fill hierarchy for.
    ///
    /// `tinted` washes the card in a colour — the hover state on action tiles.
    func glassPanel(cornerRadius: CGFloat = Theme.Radius.card, tinted: Color? = nil) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return self
            .background {
                ZStack {
                    shape.fill(.fill.quaternary)
                    if let tinted { shape.fill(tinted.opacity(0.10)) }
                }
            }
            .overlay(shape.strokeBorder(Theme.separator, lineWidth: 0.5))
    }

    /// Real Liquid Glass, for chrome that genuinely floats over other content:
    /// the screen pen palette sits above every app on screen, the screenshot
    /// editor's tool strip above the image being marked up.
    ///
    /// Falls back to a material below macOS 26, which is what floating chrome
    /// looked like before the glass API existed.
    @ViewBuilder
    func floatingGlass(cornerRadius: CGFloat = Theme.Radius.card) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self
                .background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(Theme.separator, lineWidth: 0.5))
        }
    }

    /// A recessed well inside a card: stat tiles, chips, inline fields.
    func well(cornerRadius: CGFloat = Theme.Radius.tile) -> some View {
        background(
            Theme.well,
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
    }
}

/// A card. Same name and shape as before so every call site picked up the new
/// surface without edits.
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
