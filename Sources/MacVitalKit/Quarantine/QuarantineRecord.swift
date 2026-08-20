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
