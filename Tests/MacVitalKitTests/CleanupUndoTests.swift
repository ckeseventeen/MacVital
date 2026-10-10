import XCTest
@testable import MacVitalKit

/// Undoing a cleanup is a batch of ordinary restores. These pin the parts of
/// that a batch adds: order, and what happens to the records it cannot put
/// back.
final class CleanupUndoTests: XCTestCase {

    private var sandbox: URL!
    private var store: QuarantineStore!
    private var coordinator: CleanupCoordinator!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacVitalUndo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        store = QuarantineStore(root: sandbox.appendingPathComponent("Quarantine"), retentionDays: 7)
        // Never reached: none of these records needed the helper.
        coordinator = CleanupCoordinator(rules: RuleIndex(), store: store, helper: HelperClient())
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

    private func makeFile(_ name: String, in directory: URL? = nil, contents: String = "payload") throws -> URL {
        let url = (directory ?? sandbox).appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func quarantine(_ url: URL, isDirectory: Bool = false) async throws -> QuarantineRecord {
        let item = ScanItem(
            path: url.path,
            category: .caches,
            ruleID: "cache.userCaches",
            kindHint: "测试",
            sizeBytes: 7,
            isDirectory: isDirectory
        )
        return try await store.store(item: item, decision: .allow("cache.userCaches", "test"), assessment: nil)
    }

    func testUndoPutsEveryRecordBackWhereItWas() async throws {
        let first = try makeFile("first.txt")
        let second = try makeFile("second.txt")
        let records = [try await quarantine(first), try await quarantine(second)]
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))

        let outcome = await coordinator.undo(records)

        XCTAssertEqual(Set(outcome.restored.map(\.id)), Set(records.map(\.id)))
        XCTAssertTrue(outcome.failed.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        let remaining = await store.allRecords()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testUndoNeverOverwritesAPathThatHasBeenReoccupied() async throws {
        let original = try makeFile("taken.txt", contents: "old")
        let record = try await quarantine(original)
        // Something new appeared where the old file used to be.
        try Data("new".utf8).write(to: original)

        let outcome = await coordinator.undo([record])

        XCTAssertTrue(outcome.restored.isEmpty)
        XCTAssertEqual(outcome.failed.map(\.record.id), [record.id])
        XCTAssertEqual(try String(contentsOf: original, encoding: .utf8), "new")
        let remaining = await store.allRecords()
        XCTAssertEqual(remaining.map(\.id), [record.id], "A record that could not go back stays restorable")
    }

    func testRecordsAlreadyRestoredByHandAreNotReportedAsFailures() async throws {
        let original = try makeFile("handled.txt")
        let record = try await quarantine(original)
        try await coordinator.restore(record)

        let outcome = await coordinator.undo([record])

        XCTAssertEqual(outcome.alreadyHandled.map(\.id), [record.id])
        XCTAssertTrue(outcome.failed.isEmpty)
        XCTAssertTrue(outcome.restored.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    }

    func testFolderMovedAfterItsContentsComesBackFirst() async throws {
        let folder = sandbox.appendingPathComponent("Folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = try makeFile("inner.txt", in: folder)
        // The order a cleanup would produce: the file, then the folder it
        // left empty.
        let fileRecord = try await quarantine(file)
        let folderRecord = try await quarantine(folder, isDirectory: true)

        let outcome = await coordinator.undo([fileRecord, folderRecord])

        XCTAssertTrue(outcome.failed.isEmpty, "\(outcome.failed.map(\.reason))")
        XCTAssertEqual(outcome.restored.map(\.id), [folderRecord.id, fileRecord.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }
}
