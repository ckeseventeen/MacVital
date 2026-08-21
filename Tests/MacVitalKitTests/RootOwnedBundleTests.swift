import XCTest
@testable import MacVitalKit

/// A `.pkg` installer writes its app as `root:wheel`, and `/Applications` is
/// full of them. Those bundles were refused outright — the blocker that exists
/// to stop a tree stranding in quarantine treated "root owns it" the same as
/// "an app is protecting itself", so the uninstaller could not remove the one
/// thing it is named after, on any build, while advising a `chmod` that needs
/// `sudo` and is not the fix.
final class RootOwnedBundleTests: XCTestCase {

    private var sandbox: URL!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacVitalRootOwned-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        let enumerator = FileManager.default.enumerator(atPath: sandbox.path)
        while let relative = enumerator?.nextObject() as? String {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: sandbox.appendingPathComponent(relative).path
            )
        }
        try? FileManager.default.removeItem(at: sandbox)
    }

    // MARK: - Which rule covers a bundle

    /// Ownership decides, not location: the same path is removable by the user
    /// when they dragged it from a disk image.
    func testUserOwnedBundleUsesTheUnprivilegedRule() throws {
        let bundle = sandbox.appendingPathComponent("Dragged.app", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)

        XCTAssertEqual(
            AppUninstallPlanner.bundleRuleID(for: bundle.path, home: "/Users/nobody"),
            "uninstall.appBundle"
        )
    }

    func testBundleInsideHomeUsesTheHomeRule() {
        XCTAssertEqual(
            AppUninstallPlanner.bundleRuleID(for: "/Users/nobody/Applications/Thing.app", home: "/Users/nobody"),
            "uninstall.userAppBundle"
        )
    }

    /// `/usr/bin/login` stands in for any root-owned path: the test cannot
    /// create one without `sudo`, but the question — "is this owned by someone
    /// other than me" — is the same.
    func testRootOwnedBundleUsesThePrivilegedRule() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: "/usr/bin/login"))
        XCTAssertEqual(
            AppUninstallPlanner.bundleRuleID(for: "/usr/bin/login", home: "/Users/nobody"),
            "uninstall.rootAppBundle"
        )
    }

    /// Both bundle rules describe the same shape of path; only one asks for
    /// root. If that stopped being true the planner's choice would be moot.
    func testTheTwoBundleRulesDifferOnlyInPrivilege() throws {
        let index = RuleIndex()
        let plain = try XCTUnwrap(index.rule(for: "uninstall.appBundle"))
        let privileged = try XCTUnwrap(index.rule(for: "uninstall.rootAppBundle"))

        XCTAssertEqual(plain.pattern.raw, privileged.pattern.raw)
        XCTAssertFalse(plain.requiresPrivilege)
        XCTAssertTrue(privileged.requiresPrivilege)
        XCTAssertFalse(privileged.autoSelectable, "removing an app is never a default")
    }

    /// The carve-out that lets a two-component path through at all. Without it
    /// the privileged rule would be denied as "shallower than three
    /// components" before ownership ever mattered.
    func testApplicationBundlesSurviveTheShallowPathGuard() {
        let paths = ProtectedPaths()
        XCTAssertNil(paths.isHardDenied("/Applications/UURemote.app"))
        // Still denied, and the reason differs by which guard catches them
        // first: Safari is named on the prefix list, while `Utilities` is not
        // a `.app` at all and so never earns the carve-out in the first place.
        XCTAssertEqual(paths.isHardDenied("/Applications/Safari.app"), .criticalPath)
        XCTAssertEqual(paths.isHardDenied("/Applications/Utilities"), .pathTooShallow)
        XCTAssertNotNil(paths.isHardDenied("/Applications"))
    }

    // MARK: - Telling the two causes apart

    /// A read-only directory this user owns is the self-protection case, and
    /// root would not help: the advice is `chmod`, and it stays a deny.
    func testOwnUnwritableDirectoryIsNotAPrivilegeProblem() throws {
        let directory = sandbox.appendingPathComponent("SelfProtected", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: directory.appendingPathComponent("db"))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)

        let blocker = try XCTUnwrap(SIPGuard.removalBlocker(at: directory.path))
        XCTAssertEqual(blocker, .unwritableDirectory(path: directory.path))
        XCTAssertFalse(blocker.rootCouldRemoveIt, "chmod is the fix here, not root")
    }

    /// An ACL that denies delete stops `sudo rm` too, so privilege is never
    /// the answer for it.
    func testDeleteDenyACLIsNeverAPrivilegeProblem() {
        XCTAssertFalse(SIPGuard.RemovalBlocker.deleteDenyACL(path: "/x").rootCouldRemoveIt)
    }

    /// Ownership is the one case root gets past — which is what lets the
    /// engine route it to the helper instead of refusing.
    func testForeignOwnerIsAPrivilegeProblem() {
        XCTAssertTrue(SIPGuard.RemovalBlocker.foreignOwner(path: "/x", uid: 0).rootCouldRemoveIt)
    }

    /// An empty root-owned directory is not blocked at all: there is nothing
    /// inside it to fail on, and the move itself only needs the parent.
    func testEmptyDirectoryIsNeverABlocker() throws {
        let directory = sandbox.appendingPathComponent("Empty", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)

        XCTAssertNil(SIPGuard.removalBlocker(at: directory.path))
    }
}
