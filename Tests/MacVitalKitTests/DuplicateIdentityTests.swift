import XCTest
@testable import MacVitalKit

/// Two hard links are two names for one inode. They are byte-identical by
/// construction, so they always survive every stage of duplicate detection —
/// and removing one frees nothing, while the summary counted its full size.
///
/// The same class of untruth as the old `reclaimedBytes`: the user looks at
/// their free space afterwards and the number has not moved. APFS clones are
/// the same story with separate inodes.
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

    // MARK: - Shared blocks

    private func write(_ name: String, createdSecondsAgo age: TimeInterval) throws -> URL {
        let url = sandbox.appendingPathComponent(name)
        try Data(repeating: 7, count: 64 * 1024).write(to: url)
        try setCreated(url, secondsAgo: age)
        return url
    }

    private func clone(_ source: URL, as name: String, createdSecondsAgo age: TimeInterval) throws -> URL {
        let url = sandbox.appendingPathComponent(name)
        guard clonefile(source.path, url.path, 0) == 0 else {
            throw XCTSkip("this volume cannot clone (errno \(errno))")
        }
        try setCreated(url, secondsAgo: age)
        return url
    }

    private func setCreated(_ url: URL, secondsAgo age: TimeInterval) throws {
        try FileManager.default.setAttributes(
            [.creationDate: Date().addingTimeInterval(-age)],
            ofItemAtPath: url.path
        )
    }

    /// Fresh URLs, so no resource value cached before a date was set leaks in.
    private func plan(_ urls: [URL]) -> (keeper: String, removable: [String])? {
        DuplicateFileScanner.plan(group: urls.map { URL(fileURLWithPath: $0.path) })
            .map { ($0.keeper.path, $0.removable.map(\.path)) }
    }

    /// Finder's ⌘D makes a clone: its own inode over the same blocks.
    /// Removing it frees nothing, exactly like a hard link.
    func testPureClonesCollapseToOneFile() throws {
        let original = try write("original.bin", createdSecondsAgo: 300)
        let copy = try clone(original, as: "original copy.bin", createdSecondsAgo: 200)
        XCTAssertEqual(DuplicateFileScanner.distinctFiles([original, copy]).count, 1)
        XCTAssertNil(plan([original, copy]), "a clone pair offers nothing to remove")
    }

    func testCloneWrittenToSinceIsItsOwnFile() throws {
        let original = try write("original.bin", createdSecondsAgo: 300)
        let edited = try clone(original, as: "edited.bin", createdSecondsAgo: 200)
        let handle = try FileHandle(forWritingTo: edited)
        try handle.write(contentsOf: Data([1]))
        try handle.close()
        XCTAssertEqual(DuplicateFileScanner.distinctFiles([original, edited]).count, 2)
    }

    /// The oldest stands for its clone family, and the separate copy is what
    /// actually gives space back.
    func testIndependentCopyIsOfferedAndCloneFamilyKept() throws {
        let original = try write("original.bin", createdSecondsAgo: 300)
        let cloned = try clone(original, as: "cloned.bin", createdSecondsAgo: 200)
        let copy = try write("copy.bin", createdSecondsAgo: 100)

        let result = try XCTUnwrap(plan([cloned, copy, original]))
        XCTAssertEqual(result.keeper, original.path)
        XCTAssertEqual(result.removable, [copy.path])
    }

    /// When the separate copy is the oldest it is kept — and neither member
    /// of the clone family is offered, because removing either one alone
    /// leaves the other holding every block.
    func testFileWhoseBlocksACloneStillHoldsIsNotOffered() throws {
        let copy = try write("copy.bin", createdSecondsAgo: 300)
        let original = try write("original.bin", createdSecondsAgo: 200)
        let cloned = try clone(original, as: "cloned.bin", createdSecondsAgo: 100)

        let result = try XCTUnwrap(plan([original, cloned, copy]))
        XCTAssertEqual(result.keeper, copy.path)
        XCTAssertEqual(result.removable, [])
    }

    func testFileWithAnotherHardLinkIsNotOffered() throws {
        let keeper = try write("keeper.bin", createdSecondsAgo: 300)
        let duplicate = try write("duplicate.bin", createdSecondsAgo: 200)
        // The second name lives outside the group, as it would in a folder
        // the scan never walked.
        try FileManager.default.linkItem(at: duplicate, to: sandbox.appendingPathComponent("elsewhere.bin"))

        let result = try XCTUnwrap(plan([keeper, duplicate]))
        XCTAssertEqual(result.removable, [])
    }

    func testOrdinaryCopiesAreStillOffered() throws {
        let keeper = try write("keeper.bin", createdSecondsAgo: 300)
        let duplicate = try write("duplicate.bin", createdSecondsAgo: 200)

        let result = try XCTUnwrap(plan([duplicate, keeper]))
        XCTAssertEqual(result.keeper, keeper.path)
        XCTAssertEqual(result.removable, [duplicate.path])
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
