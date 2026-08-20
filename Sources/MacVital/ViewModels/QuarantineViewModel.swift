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
            errorMessage = "清理了 \(outcome.removed)/\(paths.count) 个无主容器，其余无法删除（可能属于 root）。"
        }
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
