import Foundation

/// What the deterministic rule engine permits. This is the *only* thing that
/// grants removal. No model output can turn a `.deny` into an `.allow`.
public enum Admission: String, Codable, Sendable {
    /// The current user can move this to quarantine directly.
    case allow
    /// Requires the privileged helper (root-owned path, /Library, etc.).
    case allowWithPrivilege
    /// Never remove. The `rationale` explains why.
    case deny
}

/// Why the engine reached its verdict. Stable IDs so we can test and log them.
public enum DenyReason: String, Codable, Sendable {
    case unknownRule
    case patternMismatch
    case systemIntegrityProtected
    case immutableFlag
    case protectedUserData
    case criticalPath
    case pathTooShallow
    case symlinkEscape
    case inUse
    case selfProtection
    case missing
    /// Needs root, on a build where the privileged helper can never connect.
    ///
    /// Distinct from `.systemIntegrityProtected`: the path is removable in
    /// principle, just not by this copy of the app. Kept separate so the UI can
    /// say "this build cannot" rather than "this file is protected", which
    /// would be false.
    case privilegedHelperUnavailable
    /// Something inside the tree cannot be removed — an ACL that denies delete,
    /// or a non-empty directory with no write permission. Moving such a tree
    /// into quarantine strands it there: it can be neither purged nor restored.
    case contentsNotRemovable
    /// The current user cannot unlink it and no privileged rule describes it.
    ///
    /// Distinct from `.privilegedHelperUnavailable`, which means "root could do
    /// this, but not on this build". Here root is not the answer either: the
    /// helper only accepts paths a `requiresPrivilege` rule can describe, so
    /// offering the helper would be offering a button that always fails.
    case notRemovableByUser
}

/// Who is holding a path open, when that is why it was refused.
///
/// The name and the PID were only ever in the rationale sentence, which meant
/// the UI could tell the user "quit it yourself" and nothing more. Carrying it
/// structurally is what lets the app offer to do it for them — the one deny
/// reason that is temporary deserves an action rather than an explanation.
public struct BlockingProcess: Hashable, Codable, Sendable {
    /// `nil` when the block came from a bundle identifier rather than a
    /// specific process — the app may have several.
    public var pid: Int32?
    public var bundleIdentifier: String?
    /// What the PID was running when this verdict was made.
    ///
    /// A PID is not a stable handle. This verdict is produced during a scan and
    /// may be acted on minutes later, and macOS recycles PIDs — by the time the
    /// user presses 强制结束, that number can belong to something else
    /// entirely. Signalling it then would kill an unrelated process, which is
    /// the one outcome a delete-safety tool must never produce.
    ///
    /// Recorded so the terminator can confirm the PID still means what it meant
    /// here before sending anything.
    public var executablePath: String?
    /// Best available label, for the button and the confirmation.
    public var name: String

    public init(
        pid: Int32? = nil,
        bundleIdentifier: String? = nil,
        executablePath: String? = nil,
        name: String
    ) {
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
        self.executablePath = executablePath
        self.name = name
    }
}

public struct RuleDecision: Hashable, Codable, Sendable {
    public var admission: Admission
    public var ruleID: String
    public var denyReason: DenyReason?
    /// Plain-language explanation, shown verbatim in the inspector.
    public var rationale: String
    /// Set only alongside `denyReason == .inUse`.
    public var blockedBy: BlockingProcess?

    public init(
        admission: Admission,
        ruleID: String,
        denyReason: DenyReason? = nil,
        rationale: String,
        blockedBy: BlockingProcess? = nil
    ) {
        self.admission = admission
        self.ruleID = ruleID
        self.denyReason = denyReason
        self.rationale = rationale
        self.blockedBy = blockedBy
    }

    public var isDenied: Bool { admission == .deny }

    public static func allow(_ ruleID: String, _ rationale: String) -> RuleDecision {
        RuleDecision(admission: .allow, ruleID: ruleID, rationale: rationale)
    }

    public static func privileged(_ ruleID: String, _ rationale: String) -> RuleDecision {
        RuleDecision(admission: .allowWithPrivilege, ruleID: ruleID, rationale: rationale)
    }

    public static func deny(_ ruleID: String, _ reason: DenyReason, _ rationale: String) -> RuleDecision {
        RuleDecision(admission: .deny, ruleID: ruleID, denyReason: reason, rationale: rationale)
    }

    /// Refused because something is running. Carries the culprit so the UI can
    /// offer to close it.
    public static func inUse(
        _ ruleID: String,
        _ rationale: String,
        blockedBy: BlockingProcess
    ) -> RuleDecision {
        RuleDecision(
            admission: .deny, ruleID: ruleID, denyReason: .inUse,
            rationale: rationale, blockedBy: blockedBy
        )
    }
}
