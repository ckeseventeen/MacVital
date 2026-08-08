import Foundation
import AppKit
import MacVitalKit
import SwiftUI

@MainActor
final class QuarantineViewModel: ObservableObject {
    @Published private(set) var records: [QuarantineRecord] = []
    @Published var errorMessage: String?
    @Published var busyID: UUID?

    private let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    var totalBytes: Int64 { records.reduce(0) { $0 + $1.sizeBytes } }

    func reload() async {
        records = await environment.quarantine.allRecords()
        await environment.refreshQuarantine()
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
