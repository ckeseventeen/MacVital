import XCTest
@testable import MacVitalKit

final class QuarantineStoreTests: XCTestCase {

    private var sandbox: URL!
    private var store: QuarantineStore!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacVitalQuarantine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        store = QuarantineStore(root: sandbox.appendingPathComponent("Quarantine"), retentionDays: 7)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

    private func makeSource(_ name: String) throws -> URL {
        let url = sandbox.appendingPathComponent(name)
        try Data("payload".utf8).write(to: url)
        return url
    }

    private func item(at url: URL) -> ScanItem {
        ScanItem(
            path: url.path,
            category: .caches,
            ruleID: "cache.userCaches",
            kindHint: "测试",
            sizeBytes: 7,
            isDirectory: false
        )
    }

    func testStoreMovesRatherThanDeletes() async throws {
        let source = try makeSource("a.txt")
        let record = try await store.store(
            item: item(at: source),
            decision: .allow("cache.userCaches", "test"),
            assessment: nil
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path), "source should be gone")
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.storedPath), "payload should be in quarantine")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: record.storedPath)), Data("payload".utf8))
    }

    func testRestorePutsItBack() async throws {
        let source = try makeSource("b.txt")
        let record = try await store.store(
            item: item(at: source),
            decision: .allow("cache.userCaches", "test"),
            assessment: nil
        )
        try await store.restore(id: record.id)

        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        let remaining = await store.allRecords()
        XCTAssertTrue(remaining.isEmpty)
    }

    /// Restoring must never clobber whatever is at the original path now.
    func testRestoreRefusesToOverwrite() async throws {
        let source = try makeSource("c.txt")
        let record = try await store.store(
            item: item(at: source),
            decision: .allow("cache.userCaches", "test"),
            assessment: nil
        )
        try Data("something new".utf8).write(to: source)

        do {
            try await store.restore(id: record.id)
            XCTFail("expected restore to refuse")
        } catch {
            XCTAssertEqual(try Data(contentsOf: source), Data("something new".utf8))
        }
    }

    func testRetentionWindowIsHonoured() async throws {
        let source = try makeSource("d.txt")
        let record = try await store.store(
            item: item(at: source),
            decision: .allow("cache.userCaches", "test"),
            assessment: nil
        )
        XCTAssertFalse(record.isExpired)
        XCTAssertGreaterThan(record.daysRemaining, 5)

        // Nothing is swept before its purge date.
        let swept = await store.sweepExpired()
        XCTAssertEqual(swept, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.storedPath))
    }

    func testExpiredRecordsAreSwept() async throws {
        let expiredStore = QuarantineStore(
            root: sandbox.appendingPathComponent("Q2"),
            retentionDays: 0
        )
        let source = try makeSource("e.txt")
        let record = try await expiredStore.store(
            item: item(at: source),
            decision: .allow("cache.userCaches", "test"),
            assessment: nil
        )

        let swept = await expiredStore.sweepExpired()
        XCTAssertEqual(swept, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: record.storedPath))
        let remaining = await expiredStore.allRecords()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testManifestSurvivesReload() async throws {
        let source = try makeSource("f.txt")
        _ = try await store.store(
            item: item(at: source),
            decision: .allow("cache.userCaches", "test"),
            assessment: nil
        )

        let reopened = QuarantineStore(root: sandbox.appendingPathComponent("Quarantine"), retentionDays: 7)
        let records = await reopened.allRecords()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.displayName, "f.txt")
    }

    func testAssessmentIsPreservedForLaterExplanation() async throws {
        let source = try makeSource("g.txt")
        let assessment = AIAssessment(
            itemID: UUID(), confidence: 0.9,
            whatItIs: "这是缓存", consequence: "会重建",
            recommendation: .safeToRemove, source: .heuristic
        )
        let record = try await store.store(
            item: item(at: source),
            decision: .allow("cache.userCaches", "test"),
            assessment: assessment
        )
        XCTAssertEqual(record.aiSummary, "这是缓存 会重建")
    }
}
