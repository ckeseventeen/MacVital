import XCTest
@testable import MacVitalKit

/// Group containers are named `group.<bundleid>` or `<TEAMID>.<bundleid>`, and
/// `InstalledAppIndex.match` did not know that.
///
/// So every sandboxed app's shared container came back `.none` — "no installed
/// app owns this" — and the residue scanner reported it as the leftovers of an
/// uninstalled app. `group.com.nebula.karing` belongs to Karing, which is
/// installed and running; wiping it makes Karing re-initialise from scratch,
/// which is exactly what the user saw, repeatedly.
///
/// `AppUninstallPlanner.name(_:belongsTo:)` has handled both prefixes since it
/// was written. The scanner's own matcher never did.
final class GroupContainerAttributionTests: XCTestCase {

    private let index = InstalledAppIndex(apps: [
        .init(bundleIdentifier: "com.nebula.karing", name: "Karing", path: "/Applications/Karing.app"),
        .init(bundleIdentifier: "com.acme.Editor", name: "Acme Editor", path: "/Applications/Acme Editor.app"),
    ])

    private func isInstalled(_ name: String) -> Bool {
        if case .installed = index.match(residueName: name) { return true }
        return false
    }

    func testPlainBundleIdentifierStillMatches() {
        XCTAssertTrue(isInstalled("com.nebula.karing"))
    }

    /// The case that wiped a running app's settings.
    func testGroupPrefixedContainerMatchesItsApp() {
        XCTAssertTrue(isInstalled("group.com.nebula.karing"))
    }

    /// The other shape macOS uses for shared containers.
    func testTeamPrefixedContainerMatchesItsApp() {
        XCTAssertTrue(isInstalled("ABCDE12345.com.nebula.karing"))
    }

    /// Extensions get their own identifier hanging off the app's, and their
    /// containers carry the same prefixes.
    func testGroupPrefixedExtensionContainerIsAttributed() {
        switch index.match(residueName: "group.com.nebula.karing.networkextension") {
        case .installed, .vendorInstalled: break
        default: XCTFail("an extension's shared container must attribute to its app")
        }
    }

    /// Narrowness still matters: stripping the prefix must not make unrelated
    /// identifiers match.
    func testUnrelatedGroupContainerIsNotClaimed() {
        XCTAssertFalse(isInstalled("group.com.other.Thing"))
    }

    func testGroupPrefixAloneIsNotAnIdentifier() {
        XCTAssertFalse(isInstalled("group"))
        XCTAssertFalse(isInstalled("group."))
    }
}
