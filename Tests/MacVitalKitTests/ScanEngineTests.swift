import XCTest
@testable import MacVitalKit

/// A scanner that reports exactly what it is told to.
private struct StubScanner: MacVitalKit.Scanner {
    let category: ScanCategory
    let items: [ScanItem]

    func scan(context: ScanContext, progress: @Sendable (ScanProgress) -> Void) async throws -> [ScanItem] {
        progress(ScanProgress(category: category, message: "stub", fraction: 1.0))
        return items
    }
}

final class ScanEngineTests: XCTestCase {

    private var sandbox: URL!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacVitalScanEngine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

    /// A path deep enough to clear the "shallower than three components" guard,
    /// so the rule engine's verdict is about the rule rather than the shape.
    private func makeFile(_ name: String) throws -> String {
        let url = sandbox.appendingPathComponent(name)
        try Data("payload".utf8).write(to: url)
        return ProtectedPaths.normalize(url.path)
    }

    private func item(path: String, category: ScanCategory, kind: String) -> ScanItem {
        ScanItem(
            path: path,
            category: category,
            ruleID: "file.large",
            kindHint: kind,
            sizeBytes: 7,
            isDirectory: false
        )
    }

    private func engine(scanners: [MacVitalKit.Scanner]) -> ScanEngine {
        ScanEngine(
            quarantineRoot: sandbox.appendingPathComponent("Quarantine").path,
            scanners: scanners
        )
    }

    // MARK: - Cross-scanner collisions

    /// The large-file and duplicate scanners walk the same roots, so one file
    /// could come back from both. That double-counted it in the summary, and
    /// ticking both rows made the second one fail during cleanup with
    /// "文件已不存在" about a file the user had just removed themselves.
    func testOnePathYieldsOneFinding() async throws {
        let path = try makeFile("shared.bin")
        let result = try await engine(scanners: [
            StubScanner(category: .duplicateFiles, items: [item(path: path, category: .duplicateFiles, kind: "副本")]),
            StubScanner(category: .largeFiles, items: [item(path: path, category: .largeFiles, kind: "大文件")]),
        ]).scan(categories: [.duplicateFiles, .largeFiles], progress: { _ in })

        XCTAssertEqual(result.findings.count, 1)
    }

    /// Scanners run concurrently, so the winner of a collision has to come from
    /// declaration order rather than from whoever happens to finish first.
    func testEarlierScannerWinsACollision() async throws {
        let path = try makeFile("shared.bin")

        for _ in 0..<5 {
            let result = try await engine(scanners: [
                StubScanner(category: .duplicateFiles, items: [item(path: path, category: .duplicateFiles, kind: "副本")]),
                StubScanner(category: .largeFiles, items: [item(path: path, category: .largeFiles, kind: "大文件")]),
            ]).scan(categories: [.duplicateFiles, .largeFiles], progress: { _ in })

            XCTAssertEqual(result.findings.first?.item.category, .duplicateFiles)
        }
    }

    func testDistinctPathsAreAllKept() async throws {
        let first = try makeFile("one.bin")
        let second = try makeFile("two.bin")
        let result = try await engine(scanners: [
            StubScanner(category: .largeFiles, items: [
                item(path: first, category: .largeFiles, kind: "大文件"),
                item(path: second, category: .largeFiles, kind: "大文件"),
            ]),
        ]).scan(categories: [.largeFiles], progress: { _ in })

        XCTAssertEqual(Set(result.findings.map(\.item.path)), [first, second])
    }

    // MARK: - Progress

    /// Every scanner reports its own 0→1. Forwarding those unchanged made the
    /// bar jump between independent timelines; the engine now combines them.
    func testProgressNeverExceedsOneAndRises() async throws {
        let path = try makeFile("one.bin")
        let recorder = FractionRecorder()

        _ = try await engine(scanners: [
            StubScanner(category: .largeFiles, items: [item(path: path, category: .largeFiles, kind: "大文件")]),
            StubScanner(category: .caches, items: []),
        ]).scan(categories: [.largeFiles, .caches], progress: { recorder.record($0.fraction) })

        let fractions = recorder.values
        XCTAssertFalse(fractions.isEmpty)
        XCTAssertTrue(fractions.allSatisfy { $0 >= 0 && $0 <= 1 }, "fractions out of range: \(fractions)")
        // Two scanners, one of them done: the combined figure must be a
        // fraction of the whole, never a single scanner's own 1.0.
        XCTAssertTrue(fractions.contains { $0 > 0 && $0 < 0.9 }, "no partial progress reported: \(fractions)")
    }

    /// The explanation pass belongs to no category. It used to be reported as
    /// `.developerResidue`, which put "开发者残留 · 生成说明" on screen.
    func testExplanationPhaseCarriesNoCategory() async throws {
        let path = try makeFile("one.bin")
        let recorder = MessageRecorder()

        _ = try await engine(scanners: [
            StubScanner(category: .largeFiles, items: [item(path: path, category: .largeFiles, kind: "大文件")]),
        ]).scan(categories: [.largeFiles], progress: { recorder.record($0) })

        let explanation = recorder.values.first { $0.message == "生成说明" }
        XCTAssertNotNil(explanation)
        XCTAssertNil(explanation?.category)
    }
}

// MARK: - Recorders

/// `progress` is `@Sendable` and called from the scanners' tasks, so the test
/// needs somewhere thread-safe to put what it sees.
private final class FractionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []

    func record(_ fraction: Double?) {
        guard let fraction else { return }
        lock.lock(); storage.append(fraction); lock.unlock()
    }

    var values: [Double] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}

private final class MessageRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ScanProgress] = []

    func record(_ progress: ScanProgress) {
        lock.lock(); storage.append(progress); lock.unlock()
    }

    var values: [ScanProgress] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}
