import Foundation

/// A best guess at who a file belongs to. Populated by scanners from cheap
/// signals; the AI layer may refine `confidence` and `label` afterwards.
public struct OwnerHint: Hashable, Codable, Sendable {
    public var bundleIdentifier: String?
    public var appName: String?
    /// For developer residue: the project directory the artifact belongs to.
    public var projectPath: String?

    public init(bundleIdentifier: String? = nil, appName: String? = nil, projectPath: String? = nil) {
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.projectPath = projectPath
    }

    public var label: String? {
        appName ?? bundleIdentifier ?? projectPath.map { ($0 as NSString).lastPathComponent }
    }
}

/// One candidate for removal, as produced by a scanner. A `ScanItem` is a
/// *proposal* — it carries no permission. Permission comes from `RuleDecision`.
public struct ScanItem: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    /// Absolute, symlink-resolved path.
    public var path: String
    public var displayName: String
    public var category: ScanCategory
    /// The rule that produced this item. The engine re-validates against it.
    public var ruleID: String
    /// Short human label for the kind of thing this is ("node_modules", "DerivedData").
    public var kindHint: String
    public var sizeBytes: Int64
    public var fileCount: Int
    public var isDirectory: Bool
    public var lastModified: Date?
    public var lastAccessed: Date?
    /// Duplicate sets and per-project groupings share a key.
    public var groupKey: String?
    public var ownerHint: OwnerHint?
    /// True when the contents can be regenerated from something still on disk
    /// (a lock file, a manifest, the network). Drives the default selection.
    public var rebuildable: Bool

    public init(
        id: UUID = UUID(),
        path: String,
        displayName: String? = nil,
        category: ScanCategory,
        ruleID: String,
        kindHint: String,
        sizeBytes: Int64,
        fileCount: Int = 1,
        isDirectory: Bool,
        lastModified: Date? = nil,
        lastAccessed: Date? = nil,
        groupKey: String? = nil,
        ownerHint: OwnerHint? = nil,
        rebuildable: Bool = false
    ) {
        self.id = id
        self.path = path
        self.displayName = displayName ?? (path as NSString).lastPathComponent
        self.category = category
        self.ruleID = ruleID
        self.kindHint = kindHint
        self.sizeBytes = sizeBytes
        self.fileCount = fileCount
        self.isDirectory = isDirectory
        self.lastModified = lastModified
        self.lastAccessed = lastAccessed
        self.groupKey = groupKey
        self.ownerHint = ownerHint
        self.rebuildable = rebuildable
    }

    public var url: URL { URL(fileURLWithPath: path) }

    /// Path with the home directory collapsed to `~`. Used everywhere the path
    /// is shown to the user, and everywhere it might leave the machine.
    public var abbreviatedPath: String { PathRedaction.abbreviate(path) }

    public var ageInDays: Int? {
        guard let date = lastModified else { return nil }
        return Calendar.current.dateComponents([.day], from: date, to: Date()).day
    }
}
