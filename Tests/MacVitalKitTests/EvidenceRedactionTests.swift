import XCTest
@testable import MacVitalKit

/// What may leave the machine.
///
/// `CloudAdvisor` is the one code path that sends anything to a remote API, and
/// it sends exactly one thing: `AIEvidence`. So the guarantees have to hold
/// here, at collection time, rather than anywhere downstream.
final class EvidenceRedactionTests: XCTestCase {

    private var sandbox: URL!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacVitalEvidence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

    private func textFile(_ name: String, contents: String) throws -> URL {
        let url = sandbox.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func item(at url: URL, category: ScanCategory, ruleID: String) -> ScanItem {
        ScanItem(
            path: url.path,
            category: category,
            ruleID: ruleID,
            kindHint: "测试",
            sizeBytes: 1024,
            isDirectory: false
        )
    }

    // MARK: - Head snippets

    /// The user's own files are never sampled. `largeFiles` and
    /// `duplicateFiles` walk ~/Documents, ~/Desktop, ~/Downloads, ~/Movies and
    /// ~/Pictures — with the cloud advisor on, the opening lines of a personal
    /// `.csv`, `.md` or `.env` were going to a remote API. The binary filter
    /// was never protection: a text file *is* the content.
    func testUserFileCategoriesAreNeverSampled() throws {
        let secret = try textFile("notes.md", contents: "API_KEY=sk-live-000 私人笔记")

        for category in [ScanCategory.largeFiles, .duplicateFiles] {
            let ruleID = category == .largeFiles ? "file.large" : "file.duplicate"
            let evidence = EvidenceCollector.collect(
                for: item(at: secret, category: category, ruleID: ruleID), rule: nil
            )
            XCTAssertNil(evidence.headSnippet, "\(category) must not sample file contents")
        }
    }

    /// Even in the residue categories, only inside ~/Library. A project
    /// artifact rule can reach into ~/Documents, and a stray file there belongs
    /// to the user, not to an app.
    func testResidueOutsideLibraryIsNotSampled() throws {
        let outside = try textFile("config.json", contents: "{\"token\":\"secret\"}")
        let evidence = EvidenceCollector.collect(
            for: item(at: outside, category: .appResidue, ruleID: "residue.applicationSupport"), rule: nil
        )
        XCTAssertNil(evidence.headSnippet)
    }

    func testLibraryResidueMayStillBeSampled() {
        // Path-based decision, so no file has to exist for the policy check.
        let inLibrary = ScanItem(
            path: "\(PathRedaction.home)/Library/Application Support/Vendor/config.json",
            category: .appResidue,
            ruleID: "residue.applicationSupport",
            kindHint: "测试",
            sizeBytes: 10,
            isDirectory: false
        )
        XCTAssertTrue(EvidenceCollector.mayReadHead(of: inLibrary),
                      "attribution needs this: a config file names its vendor in the first line")
    }

    // MARK: - Path redaction

    func testPathsLeaveNoAccountName() throws {
        let file = try textFile("thing.txt", contents: "hello")
        let evidence = EvidenceCollector.collect(
            for: item(at: file, category: .largeFiles, ruleID: "file.large"), rule: nil
        )
        let user = (PathRedaction.home as NSString).lastPathComponent
        XCTAssertFalse(evidence.redactedPath.contains(user), "redacted path still names the account")
    }

    /// The rendered prompt is what actually goes over the wire, so assert on it
    /// rather than only on the struct.
    func testRenderedPromptCarriesNoContentsForUserFiles() throws {
        let secret = try textFile("notes.md", contents: "API_KEY=sk-live-000")
        let evidence = EvidenceCollector.collect(
            for: item(at: secret, category: .largeFiles, ruleID: "file.large"), rule: nil
        )
        let message = PromptBuilder.userMessage(for: [evidence])

        XCTAssertFalse(message.contains("sk-live-000"))
        XCTAssertFalse(message.contains("head:"))
    }
}
