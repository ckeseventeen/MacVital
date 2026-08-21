import Foundation

public struct ScanOptions: Sendable, Codable, Equatable {
    /// Where to look for node_modules / Pods / target / .build.
    public var projectRoots: [String]
    /// How deep to search under each project root.
    public var projectSearchDepth: Int
    /// Minimum size for the large-file scanner.
    public var largeFileThreshold: Int64
    /// Roots for large-file and duplicate scanning.
    public var userFileRoots: [String]
    /// Cap on how many large files and duplicate groups to report.
    public var maxUserFileResults: Int
    /// Ignore developer artifacts smaller than this — noise, not signal.
    public var minimumReportedSize: Int64

    public init(
        projectRoots: [String]? = nil,
        projectSearchDepth: Int = 5,
        largeFileThreshold: Int64 = 256 * 1_000_000,
        userFileRoots: [String]? = nil,
        maxUserFileResults: Int = 300,
        minimumReportedSize: Int64 = 1_000_000
    ) {
        let home = PathRedaction.home
        self.projectRoots = projectRoots ?? [
            "\(home)/Developer", "\(home)/Projects", "\(home)/Code", "\(home)/src",
            "\(home)/Documents", "\(home)/Desktop", "\(home)/repos", "\(home)/work",
        ]
        self.projectSearchDepth = projectSearchDepth
        self.largeFileThreshold = largeFileThreshold
        // Derived from the catalog, not restated: these roots and the rules
        // that authorise removals inside them have to be the same list.
        self.userFileRoots = userFileRoots ?? RuleCatalog.userFileRoots.map {
            "\(home)/\($0.relativePath)"
        }
        self.maxUserFileResults = maxUserFileResults
        self.minimumReportedSize = minimumReportedSize
    }

    public static let `default` = ScanOptions()
}

public struct ScanContext: Sendable {
    public let rules: RuleIndex
    public let options: ScanOptions
    public let home: String

    public init(rules: RuleIndex, options: ScanOptions = .default, home: String = PathRedaction.home) {
        self.rules = rules
        self.options = options
        self.home = home
    }
}

public struct ScanProgress: Sendable {
    /// nil for phases that belong to no single category — the explanation pass
    /// at the end. That step used to be reported as `.developerResidue`, which
    /// put "开发者残留 · 生成说明" on screen while nothing of the sort was
    /// happening.
    public var category: ScanCategory?
    public var message: String
    /// nil while the total is unknown.
    public var fraction: Double?

    public init(category: ScanCategory?, message: String, fraction: Double? = nil) {
        self.category = category
        self.message = message
        self.fraction = fraction
    }
}

public protocol Scanner: Sendable {
    var category: ScanCategory { get }
    func scan(context: ScanContext, progress: @Sendable (ScanProgress) -> Void) async throws -> [ScanItem]
}
