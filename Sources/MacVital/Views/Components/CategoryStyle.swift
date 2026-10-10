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
    /// System palette colours rather than hand-mixed RGB. The comments on the
    /// old values already named the system colour each one approximated; the
    /// real ones adapt to dark mode and Increase Contrast, the approximations
    /// stayed the same in both.
    var tint: Color {
        switch self {
        case .developerResidue: return .indigo
        case .appResidue:       return .orange
        case .largeFiles:       return .pink
        case .duplicateFiles:   return .teal
        case .caches:           return .blue
        case .emptyFolders:     return .gray
        case .appUninstall:     return .red
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
