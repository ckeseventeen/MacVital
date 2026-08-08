import Foundation

public enum ByteFormat {
    private static let formatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        f.zeroPadsFractionDigits = false
        return f
    }()

    public static func string(_ bytes: Int64) -> String {
        formatter.string(fromByteCount: max(bytes, 0))
    }

    /// Compact form for badges: "1.2 GB" -> "1.2G"
    public static func compact(_ bytes: Int64) -> String {
        let units: [(Int64, String)] = [
            (1_000_000_000_000, "T"),
            (1_000_000_000, "G"),
            (1_000_000, "M"),
            (1_000, "K"),
        ]
        let value = max(bytes, 0)
        for (threshold, suffix) in units where value >= threshold {
            let scaled = Double(value) / Double(threshold)
            return scaled >= 10
                ? "\(Int(scaled.rounded()))\(suffix)"
                : String(format: "%.1f%@", scaled, suffix)
        }
        return "\(value)B"
    }
}

public enum RelativeDateFormat {
    private static let formatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    public static func string(_ date: Date?) -> String {
        guard let date else { return "未知" }
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
