import Foundation

/// One allowlist entry. Nothing is removable unless a rule matches it.
///
/// Note what a rule does *not* carry: an admission. A rule says "this shape of
/// path is a known, named, rebuildable artifact". Whether the specific instance
/// may be removed right now is decided by `RuleEngine`, which layers the SIP
/// check, the protected-path check, the in-use check and the privilege check on
/// top. Adding a rule can never bypass a guard.
public struct CleanupRule: Hashable, Sendable, Identifiable {
    public let id: String
    public let category: ScanCategory
    public let pattern: PathPattern
    /// Short label shown in the UI, e.g. "Xcode DerivedData".
    public let kind: String
    /// Human explanation of what the artifact is. This is the *deterministic*
    /// description; the AI layer may add a richer one but never replaces this.
    public let rationale: String
    /// Contents can be regenerated (lock file, manifest, network, rebuild).
    public let rebuildable: Bool
    /// May be ticked by default when the AI also agrees. False for anything
    /// whose regeneration is slow, network-bound, or user-visible.
    public let autoSelectable: Bool
    /// Path is root-owned or outside the user's writable area.
    public let requiresPrivilege: Bool
    /// Opts out of the Documents/Desktop/Downloads ban. Only for artifacts that
    /// are unambiguously build output and legitimately live next to source.
    public let allowedInUserData: Bool
    /// When set, the scanner treats this as a "search for directories named X
    /// under the configured project roots" rule rather than a fixed path.
    public let projectArtifactName: String?
    /// Sibling files whose presence proves the artifact can be rebuilt.
    public let rebuildEvidence: [String]

    public init(
        id: String,
        category: ScanCategory,
        pattern: String,
        kind: String,
        rationale: String,
        rebuildable: Bool = true,
        autoSelectable: Bool = true,
        requiresPrivilege: Bool = false,
        allowedInUserData: Bool = false,
        projectArtifactName: String? = nil,
        rebuildEvidence: [String] = []
    ) {
        self.id = id
        self.category = category
        self.pattern = PathPattern(pattern)
        self.kind = kind
        self.rationale = rationale
        self.rebuildable = rebuildable
        self.autoSelectable = autoSelectable
        self.requiresPrivilege = requiresPrivilege
        self.allowedInUserData = allowedInUserData
        self.projectArtifactName = projectArtifactName
        self.rebuildEvidence = rebuildEvidence
    }
}

/// Lookup by rule ID. Built once per scan and passed to both the engine and the
/// planner so they cannot disagree about what a rule says.
public struct RuleIndex: Sendable {
    public let all: [CleanupRule]
    private let byID: [String: CleanupRule]

    public init(rules: [CleanupRule] = RuleCatalog.all) {
        self.all = rules
        self.byID = Dictionary(rules.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        assert(rules.count == byID.count, "duplicate rule IDs in catalog")
    }

    public func rule(for id: String) -> CleanupRule? { byID[id] }

    public func rules(in category: ScanCategory) -> [CleanupRule] {
        all.filter { $0.category == category }
    }
}
