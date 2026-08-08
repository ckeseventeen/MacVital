import XCTest
@testable import MacVitalKit

/// Startup-item management adds no rules of its own — disabling an item is the
/// quarantine move the cleaner already performs. These tests pin that wiring,
/// because a rule rename would silently turn every "disable" into a denial the
/// user reads as "the feature is broken".
final class LoginItemTests: XCTestCase {

    func testEveryScopeMapsToARuleThatExists() {
        let index = RuleIndex()
        for scope in [LoginItem.Scope.userAgent, .systemAgent, .daemon] {
            XCTAssertNotNil(
                index.rule(for: scope.ruleID),
                "\(scope.rawValue) maps to \(scope.ruleID) but the catalog has no such rule"
            )
        }
    }

    /// The two root-owned directories must route through privileged rules, and
    /// the user's own must not — otherwise the app either asks for admin rights
    /// it does not need, or tries to write to /Library without them.
    func testPrivilegeMatchesTheRuleItClaims() {
        let index = RuleIndex()
        for scope in [LoginItem.Scope.userAgent, .systemAgent, .daemon] {
            let rule = index.rule(for: scope.ruleID)!
            XCTAssertEqual(
                rule.requiresPrivilege, scope.requiresPrivilege,
                "\(scope.rawValue): scope says privilege=\(scope.requiresPrivilege), rule says \(rule.requiresPrivilege)"
            )
        }
    }

    /// A scope's directory has to be inside the path its rule matches, or the
    /// engine's pattern re-validation rejects every item the scanner produces.
    func testScopeDirectoriesMatchTheirRulePatterns() {
        let index = RuleIndex()
        for scope in [LoginItem.Scope.userAgent, .systemAgent, .daemon] {
            let rule = index.rule(for: scope.ruleID)!
            let probe = "\(scope.directory)/com.example.agent.plist"
            XCTAssertTrue(
                rule.pattern.matches(ProtectedPaths.normalize(probe)),
                "\(probe) does not match \(rule.pattern.raw)"
            )
        }
    }

    /// Nothing here may be auto-selectable. A heuristic does not get to
    /// pre-tick "stop this from running at boot".
    func testStartupRulesAreNeverAutoSelectable() {
        let index = RuleIndex()
        for scope in [LoginItem.Scope.userAgent, .systemAgent, .daemon] {
            XCTAssertFalse(index.rule(for: scope.ruleID)!.autoSelectable, scope.ruleID)
        }
    }

    func testOrphanDetection() {
        let alive = LoginItem(
            path: "/Library/LaunchDaemons/com.example.plist", scope: .daemon, label: "com.example",
            program: "/bin/sh", programExists: true, runAtLoad: true, keepAlive: false,
            ownerName: nil, sizeBytes: 100, modified: nil
        )
        let dead = LoginItem(
            path: "/Library/LaunchDaemons/com.gone.plist", scope: .daemon, label: "com.gone",
            program: "/Applications/Gone.app/Contents/MacOS/Gone", programExists: false,
            runAtLoad: true, keepAlive: false, ownerName: nil, sizeBytes: 100, modified: nil
        )
        // No program at all is not an orphan — some jobs are socket-activated
        // and define no Program key, and calling those broken would be wrong.
        let programless = LoginItem(
            path: "/Library/LaunchDaemons/com.socket.plist", scope: .daemon, label: "com.socket",
            program: nil, programExists: false, runAtLoad: false, keepAlive: false,
            ownerName: nil, sizeBytes: 100, modified: nil
        )

        XCTAssertFalse(alive.isOrphaned)
        XCTAssertTrue(dead.isOrphaned)
        XCTAssertFalse(programless.isOrphaned)
    }

    /// The generated `ScanItem` is what the rule engine sees. If the rule ID or
    /// the path drift, the engine denies with `unknownRule` or `patternMismatch`.
    func testScanItemCarriesTheScopeRule() {
        let item = LoginItem(
            path: "\(PathRedaction.home)/Library/LaunchAgents/com.example.plist",
            scope: .userAgent, label: "com.example", program: "/bin/sh", programExists: true,
            runAtLoad: true, keepAlive: false, ownerName: "Example", sizeBytes: 512, modified: nil
        )
        let scanItem = LoginItemScanner.scanItem(for: item)
        XCTAssertEqual(scanItem.ruleID, "residue.launchAgents")
        XCTAssertEqual(scanItem.path, item.path)
        XCTAssertFalse(scanItem.isDirectory)
        // A zero size would make the item invisible in size-sorted lists.
        XCTAssertGreaterThan(scanItem.sizeBytes, 0)
    }
}
