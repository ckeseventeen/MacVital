import XCTest
@testable import MacVitalKit

final class EmptyDirectoryScannerTests: XCTestCase {

    private var home: URL!
    private let scanner = EmptyDirectoryScanner()

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacVitalEmpty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent("Library/Application Support"),
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    // MARK: - Fixtures

    private var supportRoot: URL { home.appendingPathComponent("Library/Application Support") }

    @discardableResult
    private func makeDirectory(_ relativePath: String) throws -> URL {
        let url = supportRoot.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func makeFile(_ relativePath: String, contents: String = "x") throws {
        let url = supportRoot.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    private func scan() async throws -> [ScanItem] {
        // `userFileRoots` is pointed at the sandbox too, so the scan cannot
        // reach the real home directory from a test.
        let options = ScanOptions(userFileRoots: [home.appendingPathComponent("Files").path])
        let context = ScanContext(rules: RuleIndex(), options: options, home: home.path)
        return try await scanner.scan(context: context, progress: { _ in })
    }

    private func scannedNames() async throws -> Set<String> {
        Set(try await scan().map(\.displayName))
    }

    // MARK: - Basics

    func testEmptyDirectoryIsReported() async throws {
        try makeDirectory("Vendor")
        let names = try await scannedNames()
        XCTAssertTrue(names.contains("Vendor"))
    }

    func testDirectoryWithAFileIsNotReported() async throws {
        try makeFile("Vendor/state.db")
        let names = try await scannedNames()
        XCTAssertFalse(names.contains("Vendor"))
    }

    /// Finder leaves `.DS_Store` in any directory a window has been opened on.
    /// Counting it as content would hide almost every genuinely empty folder.
    func testDirectoryWithOnlyDSStoreIsReported() async throws {
        try makeFile("Vendor/.DS_Store", contents: "")
        let names = try await scannedNames()
        XCTAssertTrue(names.contains("Vendor"))
    }

    // MARK: - Only the top of a run

    /// Removing the parent takes the children with it. Listing all four rows
    /// would let the user tick both a parent and a child, and then one of the
    /// two fails during cleanup for no reason they can see.
    func testOnlyTheTopmostEmptyDirectoryIsReported() async throws {
        try makeDirectory("Vendor/Logs/Archive")
        let items = try await scan()
        let names = Set(items.map(\.displayName))

        XCTAssertTrue(names.contains("Vendor"))
        XCTAssertFalse(names.contains("Logs"))
        XCTAssertFalse(names.contains("Archive"))
        XCTAssertEqual(items.first { $0.displayName == "Vendor" }?.kindHint,
                       "空目录（含 2 个同样为空的子目录）")
    }

    func testAFileDeepInsideKeepsTheWholeRun() async throws {
        try makeFile("Vendor/Logs/Archive/old.log")
        let names = try await scannedNames()
        XCTAssertFalse(names.contains("Vendor"))
        XCTAssertFalse(names.contains("Logs"))
        XCTAssertFalse(names.contains("Archive"))
    }

    // MARK: - Things that must never be touched

    /// An app with an empty `Resources/` is a shipped bundle, not residue.
    func testPackagesAreNotDescendedInto() async throws {
        let bundle = try makeDirectory("Thing.app/Contents/Resources")
        _ = bundle
        let names = try await scannedNames()
        XCTAssertFalse(names.contains("Resources"))
        XCTAssertFalse(names.contains("Contents"))
    }

    func testSymlinkCountsAsContent() async throws {
        let directory = try makeDirectory("Vendor")
        let target = home.appendingPathComponent("target.txt")
        try Data("t".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("link"), withDestinationURL: target
        )

        let names = try await scannedNames()
        XCTAssertFalse(names.contains("Vendor"), "a symlink is content, and must not be followed")
    }

    /// `~/Library/Caches` being empty is a normal state, not residue — and the
    /// engine would deny it anyway, so proposing it only produces a locked row.
    func testRootItselfIsNeverReported() async throws {
        let names = try await scannedNames()
        XCTAssertFalse(names.contains("Application Support"))
    }

    // MARK: - Reporting

    /// Removing an empty directory returns no meaningful space. Reporting the
    /// directory entry's few KB would inflate "可回收" with bytes the user does
    /// not get back.
    func testSizeIsReportedAsZero() async throws {
        try makeDirectory("Vendor")
        let item = try await scan().first { $0.displayName == "Vendor" }
        XCTAssertEqual(item?.sizeBytes, 0)
        XCTAssertEqual(item?.fileCount, 0)
    }

    /// Nothing here may be pre-ticked: an empty directory is occasionally a
    /// mount point or a placeholder something at runtime depends on.
    func testNothingIsAutoSelected() async throws {
        try makeDirectory("Vendor")
        let items = try await scan()
        XCTAssertFalse(items.isEmpty)

        let index = RuleIndex()
        for item in items {
            let rule = try XCTUnwrap(index.rule(for: item.ruleID), "unknown rule \(item.ruleID)")
            XCTAssertFalse(rule.autoSelectable, "\(rule.id) must not auto-select")
        }
        XCTAssertTrue(ScanCategory.emptyFolders.requiresExplicitSelection)
    }

    func testRuleIDsResolveInTheCatalog() async throws {
        try makeDirectory("Vendor")
        let index = RuleIndex()
        for item in try await scan() {
            XCTAssertNotNil(index.rule(for: item.ruleID), "unknown rule \(item.ruleID)")
        }
    }
}
