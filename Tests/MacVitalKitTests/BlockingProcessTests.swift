import XCTest
@testable import MacVitalKit

/// `.inUse` is the only deny reason the user can clear, and the app now offers
/// a button that closes whatever is holding the item. That button is built
/// entirely from `RuleDecision.blockedBy` — if the engine stops naming the
/// blocker, the deny still reads correctly and the button silently disappears,
/// which is the kind of regression nothing else here would catch.
///
/// The terminator itself lives in the app target, which has no tests; this is
/// the seam where its input can be pinned.
final class BlockingProcessTests: XCTestCase {

    private var sandbox: URL!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacVitalBlocking-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

    private var rule: CleanupRule {
        CleanupRule(
            id: "test.sandbox",
            category: .developerResidue,
            pattern: "\(ProtectedPaths.normalize(sandbox.path))/**",
            kind: "测试",
            rationale: "测试用"
        )
    }

    private func engine(_ entries: [RunningProcessIndex.Entry]) -> RuleEngine {
        RuleEngine(
            rules: RuleIndex(rules: [rule]),
            processIndex: RunningProcessIndex(entries: entries),
            privilegedRemovalPossible: true
        )
    }

    private func item(at url: URL, owner: OwnerHint? = nil) -> ScanItem {
        ScanItem(
            path: ProtectedPaths.normalize(url.path),
            category: .developerResidue,
            ruleID: "test.sandbox",
            kindHint: "测试",
            sizeBytes: 7,
            isDirectory: true,
            ownerHint: owner
        )
    }

    /// A build directory a compiler is writing into. The blocker is a bare
    /// process, so the button has to address it by PID.
    func testExecutingProcessIsNamedWithItsPID() throws {
        let directory = sandbox.appendingPathComponent("build", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("compiler")
        try Data("binary".utf8).write(to: executable)

        let decision = engine([
            .init(pid: 4242, executablePath: executable.path, bundleIdentifier: nil, localizedName: "compiler")
        ]).evaluate(item(at: directory))

        XCTAssertEqual(decision.denyReason, .inUse)
        let blocker = try XCTUnwrap(decision.blockedBy, "an .inUse deny must name what is holding it")
        XCTAssertEqual(blocker.pid, 4242)
        XCTAssertEqual(blocker.name, "compiler")
    }

    /// A running app's container. Here the bundle identifier is the better
    /// address: quitting through it runs the app's real quit path, while
    /// signalling one of its PIDs does not.
    func testRunningOwnerIsNamedByBundleIdentifier() throws {
        let container = sandbox.appendingPathComponent("Container", isDirectory: true)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: container.appendingPathComponent("state.db"))

        let decision = engine([
            .init(pid: 99, executablePath: "/Applications/Example.app/Contents/MacOS/Example",
                  bundleIdentifier: "com.example.app", localizedName: "Example")
        ]).evaluate(item(at: container, owner: OwnerHint(bundleIdentifier: "com.example.app", appName: "Example")))

        XCTAssertEqual(decision.denyReason, .inUse)
        let blocker = try XCTUnwrap(decision.blockedBy)
        XCTAssertEqual(blocker.bundleIdentifier, "com.example.app")
        XCTAssertEqual(blocker.name, "Example")
    }

    /// Nothing running, nothing to offer closing. A blocker on a verdict that
    /// is not `.inUse` would put a "quit it" button on a row where quitting
    /// changes nothing.
    func testAdmittedItemNamesNoBlocker() throws {
        let directory = sandbox.appendingPathComponent("free", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: directory.appendingPathComponent("file.bin"))

        let decision = engine([]).evaluate(item(at: directory))
        XCTAssertEqual(decision.admission, .allow, decision.rationale)
        XCTAssertNil(decision.blockedBy)
    }
}
