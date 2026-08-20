import XCTest
@testable import MacVitalKit

/// Coverage tests for `AppUninstallPlanner`, built against a synthetic home
/// directory.
///
/// These exist because "卸载干净" is a claim about *coverage*, and coverage is
/// exactly the thing that cannot be verified by reading the code — the planner
/// looks correct whether or not it knows about `~/Library/Cookies`. Each test
/// below plants a real file where a real app would leave one and asserts the
/// planner proposes it.
final class UninstallCoverageTests: XCTestCase {

    private var home: URL!
    private var planner: AppUninstallPlanner!

    private let app = InstalledAppIndex.App(
        bundleIdentifier: "com.acme.Editor",
        name: "Acme Editor",
        path: "/Applications/Acme Editor.app"
    )

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacVitalHome-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        planner = AppUninstallPlanner(home: home.path)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    // MARK: - Fixtures

    @discardableResult
    private func plant(_ relativePath: String, contents: String = "x") throws -> URL {
        let url = home.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func plantBundle(_ relativePath: String, identifier: String) throws -> URL {
        let bundle = home.appendingPathComponent(relativePath)
        let contents = bundle.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": identifier]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return bundle
    }

    private func plantContainer(uuid: String, owner: String?) throws -> URL {
        let container = home.appendingPathComponent("Library/Containers/\(uuid)")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        try Data("payload".utf8).write(to: container.appendingPathComponent("Data.txt"))
        if let owner {
            let plist: [String: Any] = ["MCMMetadataIdentifier": owner]
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: container.appendingPathComponent(".com.apple.containermanagerd.metadata.plist"))
        }
        return container
    }

    private func plannedPaths() -> Set<String> {
        Set(planner.plan(for: app).map(\.item.path))
    }

    private func assertPlanned(_ url: URL, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        let expected = ProtectedPaths.normalize(url.path)
        XCTAssertTrue(plannedPaths().contains(expected), message, file: file, line: line)
    }

    private func assertNotPlanned(_ url: URL, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        let expected = ProtectedPaths.normalize(url.path)
        XCTAssertFalse(plannedPaths().contains(expected), message, file: file, line: line)
    }

    // MARK: - Locations that were already covered

    func testIdentifierKeyedLocationsAreStillFound() throws {
        let support = try plant("Library/Application Support/com.acme.Editor/state.db")
        let prefs = try plant("Library/Preferences/com.acme.Editor.plist")
        let container = try plant("Library/Containers/com.acme.Editor/Data.txt")

        let planned = plannedPaths()
        for url in [support.deletingLastPathComponent(), prefs, container.deletingLastPathComponent()] {
            XCTAssertTrue(planned.contains(ProtectedPaths.normalize(url.path)), "missing \(url.lastPathComponent)")
        }
    }

    /// Extensions get their own identifier hanging off the app's, and they are
    /// the bulk of what a real uninstall leaves behind.
    func testExtensionIdentifiersAreFound() throws {
        let ext = try plant("Library/Containers/com.acme.Editor.FinderSync/Data.txt")
        assertPlanned(ext.deletingLastPathComponent(), "extension container should be planned")
    }

    func testNeighbouringIdentifierIsNotClaimed() throws {
        let other = try plant("Library/Containers/com.acme.EditorPro/Data.txt")
        assertNotPlanned(other.deletingLastPathComponent(), "com.acme.EditorPro is a different app")
    }

    // MARK: - Newly covered locations

    func testCookiesAreFound() throws {
        let cookies = try plant("Library/Cookies/com.acme.Editor.binarycookies")
        assertPlanned(cookies, "~/Library/Cookies was not covered")
    }

    func testAutosaveInformationIsFound() throws {
        let autosave = try plant("Library/Autosave Information/com.acme.Editor.plist")
        assertPlanned(autosave, "~/Library/Autosave Information was not covered")
    }

    func testHelpCacheIsFound() throws {
        let help = try plant("Library/Caches/com.apple.helpd/com.acme.Editor/index")
        assertPlanned(help.deletingLastPathComponent(), "helpd cache was not covered")
    }

    /// Crash logs are `<DisplayName>_<HardwareUUID>.plist`, so they match on
    /// neither the identifier nor an exact name.
    func testCrashReportsAreFoundByNamePrefix() throws {
        let crash = try plant("Library/Application Support/CrashReporter/Acme Editor_F73D1360-0A2A-5307-9118-485B2619AA3B.plist")
        assertPlanned(crash, "crash report was not covered")
    }

    func testCrashReportsOfAnotherAppAreNotClaimed() throws {
        let other = try plant("Library/Application Support/CrashReporter/Acme Editor Helper_F73D1360-0A2A-5307-9118-485B2619AA3B.plist")
        assertNotPlanned(other, "the underscore anchor should stop this matching")
    }

    /// Plug-in directories hold product-named bundles, so the planner reads
    /// each bundle's own identifier rather than guessing from the filename.
    func testPluginBundleIsMatchedByItsOwnIdentifier() throws {
        let plugin = try plantBundle("Library/QuickLook/Acme Preview.qlgenerator", identifier: "com.acme.Editor.QuickLook")
        assertPlanned(plugin, "plug-in bundle was not covered")
    }

    func testPluginBundleOfAnotherVendorIsNotClaimed() throws {
        let plugin = try plantBundle("Library/QuickLook/Acme Preview.qlgenerator", identifier: "com.other.Thing")
        assertNotPlanned(plugin, "matching must use the bundle's identifier, not its filename")
    }

    func testAudioPluginIsCovered() throws {
        let plugin = try plantBundle("Library/Audio/Plug-Ins/Components/Acme.component", identifier: "com.acme.Editor.AU")
        assertPlanned(plugin, "audio plug-in directory was not covered")
    }

    /// The case that put an unattributable blob in quarantine: macOS named the
    /// container with a UUID, so nothing about its path names the owner.
    func testUUIDContainerIsMatchedViaMetadata() throws {
        let container = try plantContainer(uuid: "4848CFC5-048C-4C21-92D3-85AC0EF163D8", owner: "com.acme.Editor")
        assertPlanned(container, "UUID container was not resolved through its metadata")
    }

    func testUUIDContainerOfAnotherAppIsNotClaimed() throws {
        let container = try plantContainer(uuid: "11111111-2222-3333-4444-555555555555", owner: "com.other.Thing")
        assertNotPlanned(container, "metadata identifies a different owner")
    }

    func testUUIDContainerWithoutMetadataIsLeftAlone() throws {
        let container = try plantContainer(uuid: "22222222-3333-4444-5555-666666666666", owner: nil)
        assertNotPlanned(container, "no metadata means no attribution, so no claim")
    }

    // MARK: - The "clean" invariant

    /// Plant residue everywhere the planner knows about, remove exactly what it
    /// proposes, then plan again and expect nothing.
    ///
    /// This is the property the uninstall page's post-run check reports to the
    /// user, tested here at the level that can actually assert it. A location
    /// the planner cannot see fails this test rather than quietly leaving
    /// something behind — which is how the gaps that prompted this work went
    /// unnoticed in the first place.
    func testSecondPlanIsEmptyAfterRemovingTheFirst() throws {
        try plant("Library/Application Support/com.acme.Editor/state.db")
        try plant("Library/Application Support/com.acme.Editor.Helper/aux.db")
        try plant("Library/Caches/com.acme.Editor/blob")
        try plant("Library/Preferences/com.acme.Editor.plist")
        try plant("Library/Preferences/ByHost/com.acme.Editor.ABC.plist")
        try plant("Library/Containers/com.acme.Editor/Data.txt")
        try plant("Library/Group Containers/ABCDE12345.com.acme.Editor/shared.db")
        try plant("Library/Application Scripts/com.acme.Editor.FinderSync/script")
        try plant("Library/Saved Application State/com.acme.Editor.savedState/window")
        try plant("Library/HTTPStorages/com.acme.Editor/cookies")
        try plant("Library/WebKit/com.acme.Editor/local")
        try plant("Library/Logs/com.acme.Editor/run.log")
        try plant("Library/LaunchAgents/com.acme.Editor.plist")
        try plant("Library/Cookies/com.acme.Editor.binarycookies")
        try plant("Library/Autosave Information/com.acme.Editor.plist")
        try plant("Library/Caches/com.apple.helpd/com.acme.Editor/index")
        try plant("Library/Application Support/CrashReporter/Acme Editor_ABC.plist")
        try plant("Library/Application Support/Acme Editor/legacy.db")
        _ = try plantBundle("Library/QuickLook/Acme.qlgenerator", identifier: "com.acme.Editor.QL")
        _ = try plantContainer(uuid: "4848CFC5-048C-4C21-92D3-85AC0EF163D8", owner: "com.acme.Editor")

        let first = planner.plan(for: app)
        XCTAssertGreaterThan(first.count, 15, "fixture should exercise most locations")

        for candidate in first {
            try FileManager.default.removeItem(atPath: candidate.item.path)
        }

        let second = planner.plan(for: app)
        XCTAssertTrue(
            second.isEmpty,
            "uninstall left residue behind: " + second.map { PathRedaction.abbreviate($0.item.path) }.joined(separator: ", ")
        )
    }

    /// The other half of the same claim: removing one app's residue must not
    /// take a neighbour's with it.
    func testRemovingOneAppLeavesAnotherIntact() throws {
        try plant("Library/Application Support/com.acme.Editor/state.db")
        let neighbour = try plant("Library/Application Support/com.other.Thing/state.db")
        let sibling = try plant("Library/Preferences/com.acme.EditorPro.plist")

        for candidate in planner.plan(for: app) {
            try? FileManager.default.removeItem(atPath: candidate.item.path)
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: neighbour.path), "another vendor's data was removed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sibling.path), "a neighbouring identifier was removed")
    }

    // MARK: - Rule coverage

    /// Every path the planner proposes has to be describable by a rule in the
    /// shared catalog, or the engine denies it with `patternMismatch` and the
    /// row shows up locked. A location added to the planner without a matching
    /// rule looks like coverage and delivers none.
    func testEveryPlannedRuleExistsInTheCatalog() throws {
        try plant("Library/Cookies/com.acme.Editor.binarycookies")
        try plant("Library/Autosave Information/com.acme.Editor.plist")
        try plant("Library/Application Support/CrashReporter/Acme Editor_ABC.plist")
        try plant("Library/Caches/com.apple.helpd/com.acme.Editor/index")
        _ = try plantBundle("Library/QuickLook/Acme.qlgenerator", identifier: "com.acme.Editor.QL")
        _ = try plantContainer(uuid: "4848CFC5-048C-4C21-92D3-85AC0EF163D8", owner: "com.acme.Editor")

        let index = RuleIndex()
        for candidate in planner.plan(for: app) {
            XCTAssertNotNil(
                index.rule(for: candidate.item.ruleID),
                "planner produced unknown rule \(candidate.item.ruleID) for \(candidate.item.path)"
            )
        }
    }
}
