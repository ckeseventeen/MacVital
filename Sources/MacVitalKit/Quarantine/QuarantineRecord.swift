import Foundation

/// One thing that was removed, and everything needed to put it back.
public struct QuarantineRecord: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    /// Where it came from. Restore puts it back here, and refuses if something
    /// else has since appeared at that path.
    public var originalPath: String
    /// Path inside the quarantine store.
    public var storedPath: String
    public var displayName: String
    public var category: ScanCategory
    public var sizeBytes: Int64
    public var quarantinedAt: Date
    /// Hard delete happens after this date, not before.
    public var purgeAfter: Date
    public var ruleID: String
    /// The engine's rationale, frozen at removal time.
    public var rationale: String
    /// The model's explanation, if there was one. Kept so "why did I delete
    /// this?" is answerable a week later.
    public var aiSummary: String?
    public var usedPrivilegedHelper: Bool

    public init(
        id: UUID = UUID(),
        originalPath: String,
        storedPath: String,
        displayName: String,
        category: ScanCategory,
        sizeBytes: Int64,
        quarantinedAt: Date = Date(),
        purgeAfter: Date,
        ruleID: String,
        rationale: String,
        aiSummary: String? = nil,
        usedPrivilegedHelper: Bool = false
    ) {
        self.id = id
        self.originalPath = originalPath
        self.storedPath = storedPath
        self.displayName = displayName
        self.category = category
        self.sizeBytes = sizeBytes
        self.quarantinedAt = quarantinedAt
        self.purgeAfter = purgeAfter
        self.ruleID = ruleID
        self.rationale = rationale
        self.aiSummary = aiSummary
        self.usedPrivilegedHelper = usedPrivilegedHelper
    }

    public var isExpired: Bool { Date() >= purgeAfter }

    public var daysRemaining: Int {
        max(0, Calendar.current.dateComponents([.day], from: Date(), to: purgeAfter).day ?? 0)
    }

    public var abbreviatedOriginalPath: String { PathRedaction.abbreviate(originalPath) }
}

/// Why a record cannot be restored or purged right now.
///
/// Lives here rather than in the view model for the same reason the selection
/// rules do: this layer has tests, and the view models have none. The first
/// version of this decision shipped in `QuarantineViewModel` asking
/// `record.usedPrivilegedHelper` — a note about how the item *arrived* — and
/// both records that were actually stuck had it set to `false`. The rows that
/// needed an explanation kept offering buttons that could not work.
public enum RecordBlocker: Equatable, Sendable {
    /// Something in the stored copy denies removal: an ACL, or a non-empty
    /// directory with no write permission. Restoring is blocked too — it has
    /// to move the whole tree back out.
    case contentsNotRemovable(path: String)
    /// Root-owned, on a build whose privileged helper can never connect.
    case privilegedHelperUnavailable

    public var label: String {
        switch self {
        case .contentsNotRemovable: return "内容无法移除"
        case .privilegedHelperUnavailable: return "需要管理员权限"
        }
    }

    public var symbolName: String {
        switch self {
        case .contentsNotRemovable: return "lock.slash"
        case .privilegedHelperUnavailable: return "key.slash"
        }
    }

    public var help: String {
        switch self {
        case .contentsNotRemovable(let path):
            return "\(PathRedaction.abbreviate(path)) 挡住了整棵目录 —— 要么带着「禁止删除」的 ACL，"
                 + "要么是个没有写权限的非空目录（应用的自我保护或系统只读资源都会这样）。"
                 + "因此它既删不掉也还原不了。在访达中打开后，用 chmod u+w 或 chmod -a# 0 处理该路径。"
        case .privilegedHelperUnavailable:
            return "这一项位于系统目录，需要特权助手。当前构建是自签名的，无法使用助手"
                 + "（需要 Developer ID 签名的构建）。请在访达中手动处理。"
        }
    }

    /// The real question is whether the store can still act on this record,
    /// which only the filesystem knows.
    public static func evaluate(
        _ record: QuarantineRecord,
        privilegedRemovalPossible: Bool
    ) -> RecordBlocker? {
        if let blocker = SIPGuard.removalBlocker(at: record.storedPath) {
            return .contentsNotRemovable(path: blocker.path)
        }
        if record.usedPrivilegedHelper && !privilegedRemovalPossible {
            return .privilegedHelperUnavailable
        }
        return nil
    }
}

public enum QuarantineError: LocalizedError {
    case rootUnavailable(String)
    case sourceMissing(String)
    case destinationOccupied(String)
    case recordNotFound
    case moveFailed(String)
    case privilegeRequired
    /// The manifest is on disk but could not be decoded. Every write is refused
    /// while this holds — see `QuarantineStore.loadIfNeeded`.
    case manifestUnreadable(String)
    case manifestWriteFailed(String)

    public var errorDescription: String? {
        switch self {
        case .rootUnavailable(let detail): return "无法创建隔离区：\(detail)"
        case .sourceMissing(let path): return "源文件已不存在：\(PathRedaction.abbreviate(path))"
        case .destinationOccupied(let path):
            return "原位置已有同名文件，未覆盖：\(PathRedaction.abbreviate(path))"
        case .recordNotFound: return "找不到该隔离记录。"
        case .moveFailed(let detail): return "移动失败：\(detail)"
        case .privilegeRequired: return "该操作需要管理员授权。"
        case .manifestUnreadable(let detail):
            return "隔离区清单损坏，已停止写入以免丢失既有记录：\(detail)"
        case .manifestWriteFailed(let detail):
            return "隔离区清单写入失败：\(detail)"
        }
    }
}
