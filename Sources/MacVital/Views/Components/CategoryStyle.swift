import SwiftUI
import MacVitalKit

/// Per-category colour, defined once and used everywhere a category appears —
/// welcome cards, sidebar, result sections, the proportion bar.
///
/// This lives in the app rather than in `MacVitalKit` on purpose: the kit is
/// the safety-critical core and has no business importing SwiftUI. A colour is
/// presentation, and nothing in the rule engine should ever be able to depend
/// on one.
extension ScanCategory {
    var tint: Color {
        switch self {
        case .developerResidue: return Color(red: 0.44, green: 0.36, blue: 0.92)  // indigo
        case .appResidue:       return Color(red: 0.95, green: 0.55, blue: 0.16)  // amber
        case .largeFiles:       return Color(red: 0.93, green: 0.33, blue: 0.44)  // rose
        case .duplicateFiles:   return Color(red: 0.13, green: 0.68, blue: 0.66)  // teal
        case .caches:           return Color(red: 0.25, green: 0.56, blue: 0.98)  // blue
        case .emptyFolders:     return Color(red: 0.52, green: 0.55, blue: 0.60)  // slate
        case .appUninstall:     return Color(red: 0.85, green: 0.28, blue: 0.28)  // red
        }
    }

    /// A soft fill for the icon tile behind the glyph.
    var softTint: Color { tint.opacity(0.14) }
}

/// The rounded icon tile used for categories throughout the UI. One definition
/// so the corner radius and glyph weight cannot drift between screens.
struct CategoryIcon: View {
    let category: ScanCategory
    var size: CGFloat = 28
    var isEnabled: Bool = true

    var body: some View {
        Image(systemName: category.symbolName)
            .font(.system(size: size * 0.5, weight: .medium))
            .foregroundStyle(isEnabled ? category.tint : Color.secondary)
            .frame(width: size, height: size)
            .background(
                (isEnabled ? category.tint : Color.secondary).opacity(0.14),
                in: RoundedRectangle(cornerRadius: size * 0.29, style: .continuous)
            )
    }
}

/// Stacked proportion bar: how the reclaimable total splits across categories.
/// A single glance answers "where is my space going", which a column of numbers
/// does not.
struct CategoryProportionBar: View {
    let segments: [(category: ScanCategory, bytes: Int64)]
    var height: CGFloat = 10

    private var total: Int64 { max(segments.reduce(0) { $0 + $1.bytes }, 1) }

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 1.5) {
                ForEach(segments, id: \.category) { segment in
                    segment.category.tint
                        .frame(width: max(geometry.size.width * CGFloat(segment.bytes) / CGFloat(total) - 1.5, 0))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: height)
        .background(Color.secondary.opacity(0.12))
        .clipShape(Capsule())
    }
}
