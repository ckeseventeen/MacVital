import XCTest
@testable import MacVitalKit

/// macOS puts `group:everyone deny delete` on several `~/Library` directories
/// — `Spelling`, `FontCollections`, `Favorites` — so a stray `rm -rf` cannot
/// take them.
///
/// Nothing in the engine used to see it. `st_flags` is clear, the owner is the
/// user, the mode is 700, and `access(W_OK)` does not evaluate an ACL's delete
/// permission. Two such directories passed every check, were moved into
/// quarantine, and then could be neither purged nor restored — restoring has
/// to move them out again. They wedged a real store until the ACL was stripped
/// by hand, and the failure surfaced as a code-signing complaint about the
/// privileged helper, three layers from the truth.
final class DeleteDenyACLTests: XCTestCase {

    private var sandbox: URL!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacVitalACL-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // Strip the ACL first, or the sandbox itself cannot be torn down.
        for url in (try? FileManager.default.contentsOfDirectory(at: sandbox, includingPropertiesForKeys: nil)) ?? [] {
            Self.removeACL(at: url)
        }
        try? FileManager.default.removeItem(at: sandbox)
    }

    // MARK: - Fixtures

    @discardableResult
    private static func run(_ arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/chmod")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    private static func denyDelete(at url: URL) -> Bool {
        run(["+a", "group:everyone deny delete", url.path]) == 0
    }

    private static func removeACL(at url: URL) {
        run(["-N", url.path])
    }

    private func makeDirectory(_ name: String) throws -> URL {
        let url = sandbox.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Detection

    func testPlainDirectoryHasNoDenyACL() throws {
        let plain = try makeDirectory("plain")
        XCTAssertFalse(SIPGuard.hasDeleteDenyACL(at: plain.path))
    }

    func testDenyDeleteACLIsDetected() throws {
        let guarded = try makeDirectory("guarded")
        try XCTSkipUnless(Self.denyDelete(at: guarded), "could not set an ACL in this environment")

        XCTAssertTrue(SIPGuard.hasDeleteDenyACL(at: guarded.path))
    }

    /// The ACL is usually on a directory *inside* the thing being removed —
    /// `Vendor/Spelling` rather than `Vendor` — so checking only the top would
    /// have missed both real cases.
    func testDenyDeleteACLOnAChildIsDetected() throws {
        let parent = try makeDirectory("parent")
        let child = parent.appendingPathComponent("Spelling", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try XCTSkipUnless(Self.denyDelete(at: child), "could not set an ACL in this environment")

        XCTAssertTrue(SIPGuard.hasDeleteDenyACL(at: parent.path))
        addTeardownBlock { Self.removeACL(at: child) }
    }

    /// The check has to agree with reality: if it says the ACL is there, the
    /// delete must actually fail, and vice versa.
    func testDetectionMatchesWhatTheFilesystemDoes() throws {
        let guarded = try makeDirectory("guarded")
        try XCTSkipUnless(Self.denyDelete(at: guarded), "could not set an ACL in this environment")

        XCTAssertTrue(SIPGuard.hasDeleteDenyACL(at: guarded.path))
        XCTAssertThrowsError(try FileManager.default.removeItem(at: guarded),
                             "the ACL should make this fail — otherwise the guard is unnecessary")

        Self.removeACL(at: guarded)
        XCTAssertFalse(SIPGuard.hasDeleteDenyACL(at: guarded.path))
        XCTAssertNoThrow(try FileManager.default.removeItem(at: guarded))
    }

    // MARK: - Engine

    /// The point of all of the above: such a path never enters quarantine.
    func testRuleEngineRefusesAPathWithADenyDeleteACL() throws {
        let home = sandbox.appendingPathComponent("home", isDirectory: true)
        let caches = home.appendingPathComponent("Library/Caches", isDirectory: true)
        let target = caches.appendingPathComponent("com.acme.Editor", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try XCTSkipUnless(Self.denyDelete(at: target), "could not set an ACL in this environment")
        addTeardownBlock { Self.removeACL(at: target) }

        let engine = RuleEngine(
            rules: RuleIndex(),
            protectedPaths: ProtectedPaths(home: home.path),
            processIndex: RunningProcessIndex(entries: [])
        )
        let item = ScanItem(
            path: ProtectedPaths.normalize(target.path),
            category: .caches,
            ruleID: "cache.userCaches",
            kindHint: "测试",
            sizeBytes: 1024,
            isDirectory: true
        )

        // The rule pattern is anchored at the real home, so this fixture cannot
        // match it — assert on the *reason* instead, which is what changed.
        let decision = engine.evaluate(item)
        XCTAssertTrue(decision.isDenied)
        XCTAssertEqual(decision.denyReason, .immutableFlag,
                       "an ACL that denies delete must be refused before anything is moved")
    }
}
