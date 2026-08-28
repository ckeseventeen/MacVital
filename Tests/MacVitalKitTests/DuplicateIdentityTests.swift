import XCTest
@testable import MacVitalKit

/// Two hard links are two names for one inode. They are byte-identical by
/// construction, so they always survive every stage of duplicate detection —
/// and removing one frees nothing, while the summary counted its full size.
///
/// The same class of untruth as the old `reclaimedBytes`: the user looks at
/// their free space afterwards and the number has not moved.
final class DuplicateIdentityTests: XCTestCase {

    private var sandbox: URL!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacVitalIdentity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

    func testHardLinksCollapseToOneFile() throws {
        let original = sandbox.appendingPathComponent("original.bin")
        try Data(repeating: 7, count: 4096).write(to: original)
        let link = sandbox.appendingPathComponent("another-name.bin")
        try FileManager.default.linkItem(at: original, to: link)

        let distinct = DuplicateFileScanner.distinctFiles([original, link])
        XCTAssertEqual(distinct.count, 1, "one inode is one file, whatever it is called")
    }

    /// Genuine copies have their own inodes and must still be reported —
    /// collapsing those would delete the feature rather than fix it.
    func testSeparateCopiesAreKept() throws {
        let first = sandbox.appendingPathComponent("a.bin")
        let second = sandbox.appendingPathComponent("b.bin")
        try Data(repeating: 7, count: 4096).write(to: first)
        try Data(repeating: 7, count: 4096).write(to: second)

        XCTAssertEqual(DuplicateFileScanner.distinctFiles([first, second]).count, 2)
    }

    /// A path that cannot be read is kept rather than silently dropped: losing
    /// a candidate here would quietly shrink the group.
    func testUnreadablePathIsKept() {
        let missing = sandbox.appendingPathComponent("gone.bin")
        XCTAssertEqual(DuplicateFileScanner.distinctFiles([missing]).count, 1)
    }

    func testExecutionRevalidationAcceptsTwoUnchangedCopies() throws {
        let keeper = sandbox.appendingPathComponent("keeper.bin")
        let duplicate = sandbox.appendingPathComponent("duplicate.bin")
        let bytes = Data(repeating: 0xA7, count: 16_384)
        try bytes.write(to: keeper)
        try bytes.write(to: duplicate)
        let digest = try XCTUnwrap(DuplicateFileScanner.fullDigest(of: keeper))

        let item = ScanItem(
            path: duplicate.path,
            category: .duplicateFiles,
            ruleID: "file.duplicate.downloads",
            kindHint: "副本",
            sizeBytes: Int64(bytes.count),
            isDirectory: false,
            groupKey: digest,
            duplicateKeeperPath: keeper.path
        )
        XCTAssertTrue(DuplicateFileScanner.isStillDuplicate(item))
    }

    func testExecutionRevalidationRejectsAChangedKeeper() throws {
        let keeper = sandbox.appendingPathComponent("keeper.bin")
        let duplicate = sandbox.appendingPathComponent("duplicate.bin")
        let bytes = Data(repeating: 0xA7, count: 16_384)
        try bytes.write(to: keeper)
        try bytes.write(to: duplicate)
        let digest = try XCTUnwrap(DuplicateFileScanner.fullDigest(of: keeper))
        try Data(repeating: 0xB8, count: bytes.count).write(to: keeper)

        let item = ScanItem(
            path: duplicate.path,
            category: .duplicateFiles,
            ruleID: "file.duplicate.downloads",
            kindHint: "副本",
            sizeBytes: Int64(bytes.count),
            isDirectory: false,
            groupKey: digest,
            duplicateKeeperPath: keeper.path
        )
        XCTAssertFalse(DuplicateFileScanner.isStillDuplicate(item))
    }
}
