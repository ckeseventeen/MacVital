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

    func testFailedRestoreMarkerKeepsRecordVisibleAndRetryable() async throws {
        try await assertFailedMarkerCanRetry(restoring: true)
    }

    func testFailedPurgeMarkerKeepsRecordVisibleAndRetryable() async throws {
        try await assertFailedMarkerCanRetry(restoring: false)
    }

    private func assertFailedMarkerCanRetry(restoring: Bool) async throws {
        let source = try makeSource("marker.txt")
        let record = try await store.store(
            item: item(at: source), decision: .allow("cache.userCaches", "test"), assessment: nil
        )
        let manifest = store.root.appendingPathComponent("manifest.json")
        let backup = try Data(contentsOf: manifest)
        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
        do {
            if restoring { try await store.restore(id: record.id) }
            else { try await store.purge(id: record.id) }
            XCTFail("The pending marker must be durable before touching the payload")
        } catch {}
        let visible = await store.allRecords()
        XCTAssertEqual(visible.map(\.id), [record.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.storedPath))
        try FileManager.default.removeItem(at: manifest)
        try backup.write(to: manifest)
        if restoring { try await store.restore(id: record.id) }
        else { try await store.purge(id: record.id) }
        let remaining = await store.allRecords()
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertEqual(FileManager.default.fileExists(atPath: source.path), restoring)
    }

    func testSweepDoesNotPurgeRecordWhoseRestoreStartedWhileAwaitingHelper() async throws {
        let expiredStore = QuarantineStore(root: sandbox.appendingPathComponent("Concurrent"), retentionDays: -1)
        let first = try await expiredStore.store(
            item: item(at: makeSource("first.txt")), decision: .allow("cache.userCaches", "test"), assessment: nil
        )
        let second = try await expiredStore.store(
            item: item(at: makeSource("second.txt")), decision: .privileged("cache.userCaches", "test"),
            assessment: nil, privilegedMove: { source, destination in
                let target = URL(fileURLWithPath: destination)
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.moveItem(atPath: source, toPath: destination)
                return destination
            }
        )
        // Make the first local delete fail so the sweep suspends in its helper.
        try FileManager.default.removeItem(at: URL(fileURLWithPath: first.storedPath).deletingLastPathComponent())
        let sweepEntered = expectation(description: "sweep reached helper")
        let restoreEntered = expectation(description: "restore reached helper")
        let sweepGate = QuarantineTestGate()
        let restoreGate = QuarantineTestGate()
        let sweep = Task {
            await expiredStore.sweepExpired { _ in
                sweepEntered.fulfill()
                await sweepGate.wait()
            }
        }
        await fulfillment(of: [sweepEntered], timeout: 5)
        let restore = Task {
            try await expiredStore.restore(id: second.id) { source, destination in
                restoreEntered.fulfill()
                await restoreGate.wait()
                try FileManager.default.moveItem(atPath: source, toPath: destination)
            }
        }
        await fulfillment(of: [restoreEntered], timeout: 5)
        await sweepGate.release()
        let purged = await sweep.value
        XCTAssertEqual(purged, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.storedPath))
        await restoreGate.release()
        try await restore.value
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.originalPath))
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

    func testPendingRestoreIsReconciledAfterTheOriginalReappears() async throws {
        let root = sandbox.appendingPathComponent("RecoveredRestore", isDirectory: true)
        let items = root.appendingPathComponent("Items", isDirectory: true)
        try FileManager.default.createDirectory(at: items, withIntermediateDirectories: true)
        let id = UUID()
        let original = sandbox.appendingPathComponent("restored.txt")
        try Data("restored".utf8).write(to: original)
        let record = QuarantineRecord(
            id: id,
            originalPath: original.path,
            storedPath: items.appendingPathComponent(id.uuidString).appendingPathComponent("restored.txt").path,
            displayName: "restored.txt",
            category: .caches,
            sizeBytes: 8,
            purgeAfter: Date().addingTimeInterval(3600),
            ruleID: "cache.userCaches",
            rationale: "test",
            pendingOperation: .restoring
        )
        try writeManifest([record], at: root)

        let reopened = QuarantineStore(root: root, retentionDays: 7)
        let recovered = await reopened.allRecords()
        XCTAssertTrue(recovered.isEmpty)
    }

    func testPendingRestoreRemainsWhenBothCopiesExist() async throws {
        let root = sandbox.appendingPathComponent("AmbiguousRestore", isDirectory: true)
        let items = root.appendingPathComponent("Items", isDirectory: true)
        let id = UUID()
        let container = items.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)

        let stored = container.appendingPathComponent("payload.txt")
        let original = sandbox.appendingPathComponent("ambiguous.txt")
        try Data("quarantined".utf8).write(to: stored)
        try Data("new occupant".utf8).write(to: original)

        let record = QuarantineRecord(
            id: id,
            originalPath: original.path,
            storedPath: stored.path,
            displayName: "payload.txt",
            category: .caches,
            sizeBytes: 11,
            purgeAfter: Date().addingTimeInterval(3600),
            ruleID: "cache.userCaches",
            rationale: "test",
            pendingOperation: .restoring
        )
        try writeManifest([record], at: root)

        let reopened = QuarantineStore(root: root, retentionDays: 7)
        let recovered = await reopened.allRecords()
        XCTAssertEqual(recovered.map(\.id), [id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: stored.path))
        XCTAssertEqual(try Data(contentsOf: original), Data("new occupant".utf8))
    }

    func testPendingPurgeIsReconciledAfterTheContainerDisappears() async throws {
        let root = sandbox.appendingPathComponent("RecoveredPurge", isDirectory: true)
        let items = root.appendingPathComponent("Items", isDirectory: true)
        try FileManager.default.createDirectory(at: items, withIntermediateDirectories: true)
        let id = UUID()
        let record = QuarantineRecord(
            id: id,
            originalPath: sandbox.appendingPathComponent("gone.txt").path,
            storedPath: items.appendingPathComponent(id.uuidString).appendingPathComponent("gone.txt").path,
            displayName: "gone.txt",
            category: .caches,
            sizeBytes: 8,
            purgeAfter: Date().addingTimeInterval(3600),
            ruleID: "cache.userCaches",
            rationale: "test",
            pendingOperation: .purging
        )
        try writeManifest([record], at: root)

        let reopened = QuarantineStore(root: root, retentionDays: 7)
        let recovered = await reopened.allRecords()
        XCTAssertTrue(recovered.isEmpty)
    }

    private func writeManifest(_ records: [QuarantineRecord], at root: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(records).write(
            to: root.appendingPathComponent("manifest.json"),
            options: .atomic
        )
    }

    func testCopyFallbackAcceptsOnlyCrossDeviceErrors() {
        let crossDevice = NSError(domain: NSPOSIXErrorDomain, code: Int(EXDEV))
        let wrapped = NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileWriteUnknownError,
            userInfo: [NSUnderlyingErrorKey: crossDevice]
        )
        XCTAssertTrue(QuarantineStore.isCrossDeviceError(crossDevice))
        XCTAssertTrue(QuarantineStore.isCrossDeviceError(wrapped))
        XCTAssertFalse(QuarantineStore.isCrossDeviceError(
            NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        ))
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
                    try FileManager.default.createDirectory(
                        at: URL(fileURLWithPath: to).deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try FileManager.default.moveItem(atPath: from, toPath: to)
                    return to
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

private actor QuarantineTestGate {
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}
