import AppKit

/// Shared drawing styles, independent of overlay window lifecycle.
enum AnnotationPalette {
    /// The reference tool's 7-colour palette.
    static let colors: [NSColor] = [
        NSColor(srgbRed: 1.00, green: 0.23, blue: 0.19, alpha: 1),  // #FF3B30
        NSColor(srgbRed: 1.00, green: 0.58, blue: 0.00, alpha: 1),  // #FF9500
        NSColor(srgbRed: 1.00, green: 0.80, blue: 0.00, alpha: 1),  // #FFCC00
        NSColor(srgbRed: 0.16, green: 0.78, blue: 0.25, alpha: 1),  // #28C840
        NSColor(srgbRed: 0.22, green: 0.54, blue: 0.87, alpha: 1),  // #378ADD
        NSColor(srgbRed: 0.33, green: 0.29, blue: 0.72, alpha: 1),  // #534AB7
        NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1),  // #1D1D1F
    ]
    static let widths: [CGFloat] = [2, 4, 7, 12]

}
