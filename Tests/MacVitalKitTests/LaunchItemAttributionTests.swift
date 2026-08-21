import XCTest
@testable import MacVitalKit

/// Attributing a launchd job by its filename is close to useless, and the
/// residue scanner did exactly that.
///
/// On a real machine it reported three working services as the leftovers of
/// uninstalled apps:
///   * `com.docker.vmnetd.plist` — Docker Desktop's identifier is
///     `com.docker.docker`, so the filename matches nothing;
///   * `io.github.clash-verge-rev.clash-verge-rev.service.plist` — likewise;
///   * `com.netease.uuremote.daemon.plist` — while `UURemote.app` sat in
///     `/Applications` with its daemon loaded and running.
///
/// Acting on that would have broken a running accelerator. The plist itself
/// says who it belongs to: `Program` is a path.
///
/// But *only* a path inside an installed `.app` settles it. The first fix asked
/// merely whether the target existed, and that was wrong in the other
/// direction: uninstalling an app leaves its privileged helper in
/// `/Library/PrivilegedHelperTools`, so an orphaned daemon goes on pointing at
/// a real file forever. Docker, Clash Verge and Bitboo were all gone from
/// `/Applications` while their helpers sat there — and the "fix" hid all three.
final class LaunchItemAttributionTests: XCTestCase {

    private var sandbox: URL!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacVitalLaunch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

    // MARK: - Fixtures

    @discardableResult
    private func writePlist(_ name: String, _ contents: [String: Any]) throws -> URL {
        let url = sandbox.appendingPathComponent(name)
        let data = try PropertyListSerialization.data(fromPropertyList: contents, format: .xml, options: 0)
        try data.write(to: url)
        return url
    }

    private func makeExecutable(_ relativePath: String) throws -> URL {
        let url = sandbox.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\n".utf8).write(to: url)
        return url
    }

    // MARK: - Program

    func testProgramKeyIsRead() throws {
        let binary = try makeExecutable("helper")
        let plist = try writePlist("com.acme.daemon.plist", [
            "Label": "com.acme.daemon",
            "Program": binary.path,
        ])

        XCTAssertEqual(LaunchItemAttribution.program(atPlist: plist.path), binary.path)
        XCTAssertEqual(LaunchItemAttribution.liveness(ofPlist: plist.path), .bareHelper(program: binary.path))
    }

    /// Jobs use one or the other; `ProgramArguments` is argv, so argv[0] is the
    /// executable.
    func testProgramArgumentsFallback() throws {
        let binary = try makeExecutable("helper")
        let plist = try writePlist("com.acme.args.plist", [
            "Label": "com.acme.args",
            "ProgramArguments": [binary.path, "--daemon"],
        ])

        XCTAssertEqual(LaunchItemAttribution.program(atPlist: plist.path), binary.path)
        XCTAssertEqual(LaunchItemAttribution.liveness(ofPlist: plist.path), .bareHelper(program: binary.path))
    }

    /// The genuinely orphaned case, which must still be reported.
    func testMissingTargetIsNotClaimedToExist() throws {
        let plist = try writePlist("com.acme.gone.plist", [
            "Label": "com.acme.gone",
            "Program": sandbox.appendingPathComponent("does-not-exist").path,
        ])

        XCTAssertEqual(LaunchItemAttribution.liveness(ofPlist: plist.path), .targetMissing)
    }

    func testMalformedPlistIsNotClaimedToExist() throws {
        let url = sandbox.appendingPathComponent("broken.plist")
        try Data("not a plist".utf8).write(to: url)

        XCTAssertNil(LaunchItemAttribution.program(atPlist: url.path))
        XCTAssertEqual(LaunchItemAttribution.liveness(ofPlist: url.path), .targetMissing)
    }

    // MARK: - Enclosing bundle

    /// `/Applications/UURemote.app/Contents/MacOS/UURemoteDaemon` — the case
    /// that was misfiled.
    func testExecutableInsideAnAppBundleResolvesToIt() throws {
        let binary = try makeExecutable("UURemote.app/Contents/MacOS/UURemoteDaemon")
        let bundle = sandbox.appendingPathComponent("UURemote.app")

        XCTAssertEqual(LaunchItemAttribution.enclosingAppBundle(of: binary.path), bundle.path)
    }

    func testBareHelperHasNoEnclosingBundle() throws {
        let binary = try makeExecutable("PrivilegedHelperTools/com.acme.helper")
        XCTAssertNil(LaunchItemAttribution.enclosingAppBundle(of: binary.path))
    }

    /// Bounded walk: a path with many components must not climb out of the
    /// filesystem looking for a bundle that is not there.
    func testDeeplyNestedExecutableStopsClimbing() throws {
        let binary = try makeExecutable("a/b/c/d/e/f/g/tool")
        XCTAssertNil(LaunchItemAttribution.enclosingAppBundle(of: binary.path))
    }

    // MARK: - Live reference

    /// The real referencing check runs against the machine's own launchd
    /// directories, so assert the shape of the answer rather than planting a
    /// job in a system directory from a test.
    func testUnreferencedPathIsNotClaimedAsReferenced() throws {
        let binary = try makeExecutable("nobody-launches-this")
        XCTAssertFalse(LaunchItemAttribution.isReferencedByALiveLaunchItem(binary.path))
    }

    /// Only a *live* job's reference counts. An orphaned daemon still points at
    /// its orphaned helper, and counting that would have the two vouch for each
    /// other indefinitely — neither would ever be reported.
    func testHelperReferencedByALiveDaemonIsRecognised() throws {
        let directory = "/Library/LaunchDaemons"
        let live = ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [])
            .filter { $0.hasSuffix(".plist") }
            .map { (directory as NSString).appendingPathComponent($0) }
            .first { LaunchItemAttribution.belongsToAnInstalledApp(plist: $0) }

        let plist = try XCTUnwrap(live, "no launch daemon owned by an installed app on this machine")
        let target = try XCTUnwrap(LaunchItemAttribution.program(atPlist: plist))
        XCTAssertTrue(LaunchItemAttribution.isReferencedByALiveLaunchItem(target))
    }

    // MARK: - Liveness

    /// The conclusive "leave it alone": UURemote.app was installed and its
    /// daemon running while the scanner called it residue.
    func testProgramInsideAnInstalledAppIsLive() throws {
        let binary = try makeExecutable("UURemote.app/Contents/MacOS/UURemoteDaemon")
        let plist = try writePlist("com.netease.uuremote.daemon.plist", [
            "Label": "com.netease.uuremote.daemon",
            "Program": binary.path,
        ])

        XCTAssertEqual(
            LaunchItemAttribution.liveness(ofPlist: plist.path),
            .liveInsideApp(bundlePath: sandbox.appendingPathComponent("UURemote.app").path)
        )
        XCTAssertTrue(LaunchItemAttribution.belongsToAnInstalledApp(plist: plist.path))
    }

    func testProgramInsideARemovedAppIsOrphaned() throws {
        let binary = try makeExecutable("Gone.app/Contents/MacOS/GoneDaemon")
        let plist = try writePlist("com.acme.gone.plist", [
            "Label": "com.acme.gone",
            "Program": binary.path,
        ])
        // Remove the bundle but leave the daemon behind, as an uninstall does.
        try FileManager.default.removeItem(at: sandbox.appendingPathComponent("Gone.app"))

        XCTAssertEqual(LaunchItemAttribution.liveness(ofPlist: plist.path), .targetMissing)
        XCTAssertFalse(LaunchItemAttribution.belongsToAnInstalledApp(plist: plist.path))
    }

    /// The regression this whole change exists for: a bare privileged helper
    /// outlives its app, so its continued existence must never be read as the
    /// job being wanted.
    func testBareHelperIsNotTreatedAsLive() throws {
        let binary = try makeExecutable("PrivilegedHelperTools/com.docker.vmnetd")
        let plist = try writePlist("com.docker.vmnetd.plist", [
            "Label": "com.docker.vmnetd",
            "Program": binary.path,
        ])

        XCTAssertEqual(
            LaunchItemAttribution.liveness(ofPlist: plist.path),
            .bareHelper(program: binary.path)
        )
        XCTAssertFalse(
            LaunchItemAttribution.belongsToAnInstalledApp(plist: plist.path),
            "a helper that outlives its app must not vouch for the daemon"
        )
    }
}
