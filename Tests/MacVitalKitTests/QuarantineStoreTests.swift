import XCTest
@testable import MacVitalKit

final class QuarantineStoreTests: XCTestCase {

    var sandbox: URL!
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

    /// The retention window is a live setting. It used to be captured once when
    /// the store was constructed at launch, so changing it in Settings did
    /// nothing until the next relaunch — while the confirm sheet went on
    /// promising "N 天后才清除" with the new number.
    func testRetentionIsReadAtStoreTimeNotAtInit() async throws {
        let days = MutableDays(7)
        let live = QuarantineStore(
            root: sandbox.appendingPathComponent("Q3"),
            retentionDaysProvider: { days.value }
        )

        let first = try await live.store(
            item: item(at: try makeSource("h.txt")),
            decision: .allow("cache.userCaches", "test"),
            assessment: nil
        )

        days.value = 30
        let second = try await live.store(
            item: item(at: try makeSource("i.txt")),
            decision: .allow("cache.userCaches", "test"),
            assessment: nil
        )

        let gap = second.purgeAfter.timeIntervalSince(first.purgeAfter)
        // ~23 days apart, allowing for the two calls not being simultaneous.
        XCTAssertGreaterThan(gap, 22 * 24 * 3600)
    }

    /// A failed move must not leave its container behind: the sweep only visits
    /// directories named by a manifest record, so an orphan created here is one
    /// nothing in the app would ever collect.
    func testFailedMoveLeavesNoOrphanContainer() async throws {
        let source = try makeSource("j.txt")
        let itemsDirectory = sandbox
            .appendingPathComponent("Quarantine")
            .appendingPathComponent("Items")

        do {
            // `allowWithPrivilege` with no privileged mover is a guaranteed
            // failure *after* the container has been created.
            _ = try await store.store(
                item: item(at: source),
                decision: .privileged("cache.userCaches", "test"),
                assessment: nil
            )
            XCTFail("expected the store to refuse without a privileged mover")
        } catch {
            // expected
        }

        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: itemsDirectory.path)) ?? []
        XCTAssertTrue(leftovers.isEmpty, "orphan containers left behind: \(leftovers)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "source should be untouched")
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

/// A retention value the test can change between calls, standing in for the
/// user editing the setting mid-session.
private final class MutableDays: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Int

    init(_ value: Int) { self.storage = value }

    var value: Int {
        get { lock.lock(); defer { lock.unlock() }; return storage }
        set { lock.lock(); storage = newValue; lock.unlock() }
    }
}

/// Whether a record can still be acted on.
///
/// This decision used to live in `QuarantineViewModel`, where nothing tests it,
/// and it asked `record.usedPrivilegedHelper` — a note about how the item
/// arrived. Both records that were actually stuck had it set to `false`: they
/// were moved in as the ordinary user and only became unremovable afterwards.
/// So the flag answered a question nobody was asking, while the two rows that
/// needed an explanation kept offering buttons that could not work.
extension QuarantineStoreTests {

    private func record(
        storedPath: String,
        usedPrivilegedHelper: Bool = false
    ) -> QuarantineRecord {
        QuarantineRecord(
            originalPath: "/tmp/original",
            storedPath: storedPath,
            displayName: "测试",
            category: .caches,
            sizeBytes: 10,
            purgeAfter: Date().addingTimeInterval(86_400),
            ruleID: "cache.userCaches",
            rationale: "test",
            usedPrivilegedHelper: usedPrivilegedHelper
        )
    }

    func testOrdinaryRecordHasNoBlocker() throws {
        let stored = sandbox.appendingPathComponent("plain/payload.txt")
        try FileManager.default.createDirectory(
            at: stored.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("x".utf8).write(to: stored)

        XCTAssertNil(RecordBlocker.evaluate(record(storedPath: stored.path),
                                            privilegedRemovalPossible: true))
    }

    /// The case that actually happened: moved in as the ordinary user, so the
    /// flag says `false`, but the contents cannot be removed.
    func testUnremovableContentsAreReportedEvenWhenTheFlagSaysOtherwise() throws {
        let stored = sandbox.appendingPathComponent("stuck", isDirectory: true)
        let blocked = stored.appendingPathComponent("000RefuseWalletDBDelete", isDirectory: true)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: blocked.appendingPathComponent("permissionFile"))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: blocked.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: blocked.path)
        }

        let blocker = RecordBlocker.evaluate(
            record(storedPath: stored.path, usedPrivilegedHelper: false),
            privilegedRemovalPossible: true
        )
        XCTAssertEqual(blocker, .contentsNotRemovable(path: blocked.path))
        // The message names the offending path — "无法删除" alone leaves the
        // user to find it, which is what they had to do.
        XCTAssertTrue(blocker?.help.contains("000RefuseWalletDBDelete") == true)
    }

    func testPrivilegedRecordIsBlockedOnlyWhenTheHelperCannotWork() throws {
        let stored = sandbox.appendingPathComponent("priv/payload.txt")
        try FileManager.default.createDirectory(
            at: stored.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("x".utf8).write(to: stored)
        let privileged = record(storedPath: stored.path, usedPrivilegedHelper: true)

        XCTAssertEqual(
            RecordBlocker.evaluate(privileged, privilegedRemovalPossible: false),
            .privilegedHelperUnavailable
        )
        XCTAssertNil(RecordBlocker.evaluate(privileged, privilegedRemovalPossible: true))
    }

    /// Unremovable contents win: no amount of privilege lifts an ACL or a
    /// read-only parent, so pointing the user at the helper would misdirect.
    func testContentsBlockerTakesPrecedenceOverPrivilege() throws {
        let stored = sandbox.appendingPathComponent("both", isDirectory: true)
        let blocked = stored.appendingPathComponent("inner", isDirectory: true)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: blocked.appendingPathComponent("f"))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: blocked.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: blocked.path)
        }

        let blocker = RecordBlocker.evaluate(
            record(storedPath: stored.path, usedPrivilegedHelper: true),
            privilegedRemovalPossible: false
        )
        XCTAssertEqual(blocker, .contentsNotRemovable(path: blocked.path))
    }
}

/// What happens to the file when the manifest cannot be written.
///
/// The record is what makes a quarantined file reachable, so a record that
/// never reaches disk describes a file nothing can restore or purge. The
/// rollback for that used to remove the container unconditionally — which for
/// a privileged move, where the item cannot be put back without the helper,
/// deleted the user's file outright: not at its original path, not in
/// quarantine, and named by no record.
final class QuarantineRollbackTests: XCTestCase {

    private var sandbox: URL!
    private var root: URL!
    private var store: QuarantineStore!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacVitalRollback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        root = sandbox.appendingPathComponent("Quarantine", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        // A directory where the manifest belongs: it exists, so it is not a
        // first run, and it cannot be read or written. Every `persist` fails.
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("manifest.json"), withIntermediateDirectories: true
        )
        store = QuarantineStore(root: root, retentionDays: 7)
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

    func testUnwritableManifestPutsAnOrdinaryFileBack() async throws {
        let source = try makeSource("ordinary.txt")

        do {
            _ = try await store.store(
                item: item(at: source),
                decision: .allow("cache.userCaches", "test"),
                assessment: nil
            )
            XCTFail("expected the manifest write to fail")
        } catch {
            // expected
        }

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: source.path),
            "the file must be back where it came from"
        )
    }

    /// The one that lost data. A privileged move cannot be undone without the
    /// helper, so the container has to stay — an orphan is listed, revealed and
    /// recoverable in the quarantine screen; a deleted file is not.
    func testUnwritableManifestDoesNotDeleteAPrivilegedMove() async throws {
        let source = try makeSource("privileged.txt")

        do {
            _ = try await store.store(
                item: item(at: source),
                decision: .privileged("residue.systemLaunchDaemons", "test"),
                assessment: nil,
                privilegedMove: { from, to in
                    try FileManager.default.moveItem(atPath: from, toPath: to)
                }
            )
            XCTFail("expected the manifest write to fail")
        } catch {
            // expected
        }

        let items = root.appendingPathComponent("Items", isDirectory: true)
        let containers = (try? FileManager.default.contentsOfDirectory(atPath: items.path)) ?? []
        let survivors = containers.flatMap { container -> [String] in
            let path = (items.path as NSString).appendingPathComponent(container)
            return (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        }

        XCTAssertEqual(
            survivors, ["privileged.txt"],
            "the moved file must survive in its container rather than being deleted"
        )
    }
}
