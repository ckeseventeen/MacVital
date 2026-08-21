import XCTest
@testable import MacVitalKit

/// `measure` answers "how big is this tree", and it used to answer a different
/// question: the enumerator carried `.skipsPackageDescendants`, so anything
/// containing an `.app` reported only the bytes outside the bundle.
///
/// That is not a corner case for this app. `DerivedData/<project>` keeps its
/// build products in `Build/Products/<config>/*.app`, which is most of its
/// weight, and Sparkle-updated apps park `Autoupdate.app` under Application
/// Support — so the headline "可回收 X GB" was systematically short.
final class FileWalkerTests: XCTestCase {

    private var sandbox: URL!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacVitalWalker-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

    private func write(_ bytes: Int, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(repeating: 0, count: bytes).write(to: url)
    }

    func testMeasureCountsBytesInsideAppBundles() throws {
        try write(4096, to: sandbox.appendingPathComponent("loose.bin"))
        try write(200_000, to: sandbox.appendingPathComponent("Build/Products/Debug/App.app/Contents/MacOS/App"))

        let measured = try FileWalker.measure(sandbox)

        XCTAssertGreaterThanOrEqual(
            measured.bytes, 200_000,
            "bundle contents must count toward the tree's size"
        )
        XCTAssertEqual(measured.fileCount, 2)
    }

    func testMeasureStillIgnoresSymlinkTargets() throws {
        try write(100_000, to: sandbox.appendingPathComponent("real/payload.bin"))
        let link = sandbox.appendingPathComponent("link.bin")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: sandbox.appendingPathComponent("real/payload.bin")
        )

        let measured = try FileWalker.measure(sandbox)
        XCTAssertEqual(measured.fileCount, 1, "a symlink is a link, not a second copy")
    }

    /// `maxDepth` is a promise about how far below the root the walk reaches.
    /// The bound was tested against the parent's depth, so it went one level
    /// deeper than asked for.
    func testFindDirectoriesRespectsMaxDepth() throws {
        try FileManager.default.createDirectory(
            at: sandbox.appendingPathComponent("a/b/c/node_modules"), withIntermediateDirectories: true
        )

        // node_modules sits exactly 4 levels below the root. Depth 3 is the
        // case that pins the bound: it used to be found there, one level
        // deeper than the caller asked for.
        let shallow = try FileWalker.findDirectories(named: ["node_modules"], under: sandbox, maxDepth: 3)
        XCTAssertTrue(shallow.isEmpty, "depth 3 must not reach a match 4 levels down")

        let deep = try FileWalker.findDirectories(named: ["node_modules"], under: sandbox, maxDepth: 4)
        XCTAssertEqual(deep.count, 1, "depth 4 must reach it")
    }
}
