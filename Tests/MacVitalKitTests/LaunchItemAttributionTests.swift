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
/// Acting on that would have broken Docker, a VPN and an accelerator. The plist
/// itself says who it belongs to: `Program` is a path, and a path that exists
/// settles the question.
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
        XCTAssertTrue(LaunchItemAttribution.targetExists(forPlist: plist.path))
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
        XCTAssertTrue(LaunchItemAttribution.targetExists(forPlist: plist.path))
    }

    /// The genuinely orphaned case, which must still be reported.
    func testMissingTargetIsNotClaimedToExist() throws {
        let plist = try writePlist("com.acme.gone.plist", [
            "Label": "com.acme.gone",
            "Program": sandbox.appendingPathComponent("does-not-exist").path,
        ])

        XCTAssertFalse(LaunchItemAttribution.targetExists(forPlist: plist.path))
    }

    func testMalformedPlistIsNotClaimedToExist() throws {
        let url = sandbox.appendingPathComponent("broken.plist")
        try Data("not a plist".utf8).write(to: url)

        XCTAssertNil(LaunchItemAttribution.program(atPlist: url.path))
        XCTAssertFalse(LaunchItemAttribution.targetExists(forPlist: url.path))
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
        XCTAssertFalse(LaunchItemAttribution.isReferencedByALaunchItem(binary.path))
    }

    /// A helper that a real daemon on this machine points at must be seen as
    /// referenced — that is what keeps Docker's vmnetd out of the residue list.
    func testHelperReferencedByARealDaemonIsRecognised() throws {
        let daemons = (try? FileManager.default.contentsOfDirectory(atPath: "/Library/LaunchDaemons")) ?? []
        let targets = daemons
            .filter { $0.hasSuffix(".plist") }
            .compactMap { LaunchItemAttribution.program(atPlist: "/Library/LaunchDaemons/\($0)") }
            .filter { FileManager.default.fileExists(atPath: $0) }

        let target = try XCTUnwrap(targets.first, "no live launch daemon on this machine to test against")
        XCTAssertTrue(LaunchItemAttribution.isReferencedByALaunchItem(target))
    }
}
