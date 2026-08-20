import Foundation
import AppKit
import MacVitalKit
import SwiftUI

@MainActor
final class QuarantineViewModel: ObservableObject {
    @Published private(set) var records: [QuarantineRecord] = []
    /// Containers under `Items/` that no record points at — invisible, never
    /// restorable, never swept. See `QuarantineStore.orphanedContainers`.
    @Published private(set) var orphans: [QuarantineStore.Orphan] = []
    @Published var errorMessage: String?
    @Published var busyID: UUID?
    @Published private(set) var isReaping = false

    private let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    var totalBytes: Int64 { records.reduce(0) { $0 + $1.sizeBytes } }

    var orphanBytes: Int64 { orphans.reduce(0) { $0 + $1.sizeBytes } }
    var orphansWithContent: Int { orphans.filter { !$0.isEmpty }.count }

    func reload() async {
        records = await environment.quarantine.allRecords()
        orphans = await environment.quarantine.orphanedContainers()
        await environment.refreshQuarantine()
    }

    /// Collect every orphan in one go. There is nothing to choose between them
    /// — none is reachable from the UI and none can be restored — so a per-row
    /// list would be busywork.
    func discardOrphans() async {
        guard !orphans.isEmpty else { return }
        isReaping = true
        defer { isReaping = false }

        let paths = Set(orphans.map(\.path))
        let outcome = await environment.quarantine.discardOrphans(paths: paths)
        await reload()
        environment.refreshDiskSpace()
        if outcome.removed < paths.count {
            let stuck = paths.count - outcome.removed
            errorMessage = "清理了 \(outcome.removed)/\(paths.count) 个，还有 \(stuck) 个删不掉。"
                + "这类目录（Spelling、FontCollections 等）即使被移动过，系统仍按受保护内容对待，"
                + "需要「完整磁盘访问权限」。可以在系统设置里补上并重启 App，或用下面的按钮在访达中手动删除。"
        }
    }

    /// True when the privileged helper can never work on this build, so rows
    /// that need it should say so instead of failing on click.
    var helperUnavailableOnThisBuild: Bool { !HelperClient.isSupportedByThisBuild }

    /// Whether this record can be acted on at all right now.
    ///
    /// The first version asked `record.usedPrivilegedHelper`, which is a note
    /// about how the item *arrived* — and both records that were actually stuck
    /// had it set to `false`. They were moved in as the ordinary user and only
    /// became unremovable afterwards, because of an ACL on their contents. So
    /// the flag answered a question nobody was asking while the two rows that
    /// needed the explanation kept offering buttons that could not work.
    ///
    /// The real question is whether the store can still delete it, which only
    /// the filesystem knows.
    func blocker(for record: QuarantineRecord) -> Blocker? {
        if SIPGuard.hasDeleteDenyACL(at: record.storedPath) { return .deleteDenyACL }
        if record.usedPrivilegedHelper && helperUnavailableOnThisBuild { return .needsHelper }
        return nil
    }

    enum Blocker {
        /// An ACL on the stored copy denies deletion — and therefore also
        /// denies restoring, which has to move it out first.
        case deleteDenyACL
        case needsHelper

        var label: String {
            switch self {
            case .deleteDenyACL: return "被 ACL 锁定"
            case .needsHelper: return "需要管理员权限"
            }
        }

        var symbolName: String {
            switch self {
            case .deleteDenyACL: return "lock.slash"
            case .needsHelper: return "key.slash"
            }
        }

        var help: String {
            switch self {
            case .deleteDenyACL:
                return "系统在这份内容上设置了「禁止删除」的 ACL，所以它既删不掉也还原不了。"
                     + "在访达中打开后，可用终端执行 chmod -a# 0 <路径> 移除该 ACL，再回来操作。"
            case .needsHelper:
                return "这一项位于系统目录，需要特权助手。当前构建是自签名的，无法使用助手"
                     + "（需要 Developer ID 签名的构建）。请在访达中手动处理。"
            }
        }
    }

    func revealOrphans() {
        guard let first = orphans.first else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: first.path)])
    }

    func restore(_ record: QuarantineRecord) async {
        busyID = record.id
        defer { busyID = nil }
        do {
            try await environment.coordinator.restore(record)
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func purge(_ record: QuarantineRecord) async {
        busyID = record.id
        defer { busyID = nil }
        do {
            try await environment.coordinator.purge(record)
            await reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func purgeAll() async {
        for record in records {
            try? await environment.coordinator.purge(record)
        }
        await reload()
    }

    func revealInFinder(_ record: QuarantineRecord) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: record.storedPath)])
    }
}
