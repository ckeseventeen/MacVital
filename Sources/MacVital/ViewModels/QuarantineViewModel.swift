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

    /// Delegates to `RecordBlocker`, which lives in the kit because that is the
    /// layer with tests — and getting this decision wrong here is precisely
    /// what shipped last time.
    func blocker(for record: QuarantineRecord) -> RecordBlocker? {
        RecordBlocker.evaluate(record, privilegedRemovalPossible: HelperClient.isSupportedByThisBuild)
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
