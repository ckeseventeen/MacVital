import XCTest
@testable import MacVitalKit

/// The uninstaller is the one feature that required loosening a guard: an app
/// bundle at `/Applications/Foo.app` is two path components, and the engine
/// refuses anything shallower than three. These tests exist to prove the
/// carve-out stayed narrow.
final class ApplicationBundleCarveOutTests: XCTestCase {
    private let protectedPaths = ProtectedPaths()

    func testApplicationBundlePassesTheShallowPathGuard() {
        XCTAssertNil(protectedPaths.isHardDenied("/Applications/Acme.app"))
    }

    /// Everything the carve-out must NOT admit. The property that matters is
    /// denial; which guard catches each one is an ordering detail (a path that
    /// is both shallow and prefix-listed reports whichever runs first).
    func testCarveOutDoesNotAdmitAnythingElse() {
        for path in [
            "/Applications/Acme",              // not a bundle — the suffix is load-bearing
            "/Library/Acme",                   // the guard still works everywhere else
            "/opt/acme",
            "/Applications/Safari.app",        // Apple's own, explicitly listed
            "/Applications/Utilities",
            "/Applications",                   // the folder itself is never a target
            "/System/Applications/Mail.app",   // system bundles sit behind the /System prefix
            "/System/Library/CoreServices/Finder.app",
        ] {
            XCTAssertNotNil(protectedPaths.isHardDenied(path), "\(path) must stay denied")
        }
    }

    /// Two reasons worth pinning exactly: a bundle that clears the carve-out
    /// must still be stopped by the deny list rather than sliding through, and
    /// the shallow guard itself must be unchanged for non-bundles.
    func testDenialReasonsForTheTwoInterestingCases() {
        XCTAssertEqual(protectedPaths.isHardDenied("/Applications/Safari.app"), .criticalPath)
        XCTAssertEqual(protectedPaths.isHardDenied("/Library/Acme"), .pathTooShallow)
    }

    /// The parent has to be exactly `/Applications`. A nested bundle is deep
    /// enough to clear the guard on its own and must not rely on the carve-out.
    func testCarveOutIsAnchoredToTheApplicationsFolder() {
        XCTAssertFalse(ProtectedPaths.isApplicationBundle("/Applications/Suite/Acme.app"))
        XCTAssertFalse(ProtectedPaths.isApplicationBundle("/Users/x/Applications/Acme.app"))
        XCTAssertFalse(ProtectedPaths.isApplicationBundle("/Applications/Acme.app/Contents"))
        XCTAssertTrue(ProtectedPaths.isApplicationBundle("/Applications/Acme.app"))
    }
}

/// `/private/var/db` is on the absolute deny list because it holds the local
/// account database, the TCC stores and configuration profiles — losing any of
/// those is unrecoverable. Installer receipts are one subdirectory of it, and
/// removing them makes `pkgutil` forget a package and nothing else.
///
/// That exemption is the only hole in an otherwise absolute list, so it gets
/// the most explicit tests in the project.
final class InstallerReceiptCarveOutTests: XCTestCase {
    private let protectedPaths = ProtectedPaths()

    func testReceiptsAreReachable() {
        XCTAssertNil(protectedPaths.isHardDenied("/private/var/db/receipts/com.acme.pkg.bom"))
        XCTAssertNil(protectedPaths.isHardDenied("/private/var/db/receipts/com.acme.pkg.plist"))
    }

    /// Everything else under /private/var/db must stay denied. Each of these
    /// would be a catastrophe: `dslocal` is the local user account database.
    func testTheRestOfTheDatabaseDirectoryStaysDenied() {
        for path in [
            "/private/var/db",
            "/private/var/db/receipts",              // the directory itself, not a receipt
            "/private/var/db/dslocal",
            "/private/var/db/dslocal/nodes/Default/users/root.plist",
            "/private/var/db/ConfigurationProfiles",
            "/private/var/db/TimeMachine",
            "/private/var/db/receiptsBackup",        // sibling that merely starts the same
            "/private/var/db/receipts/nested/deep.bom",
        ] {
            XCTAssertEqual(
                protectedPaths.isHardDenied(path), .criticalPath,
                "\(path) must stay denied"
            )
        }
    }

    func testCarveOutPredicateIsAnchored() {
        XCTAssertTrue(ProtectedPaths.isInstallerReceipt("/private/var/db/receipts/a.bom"))
        XCTAssertFalse(ProtectedPaths.isInstallerReceipt("/private/var/db/receipts"))
        XCTAssertFalse(ProtectedPaths.isInstallerReceipt("/private/var/db/receipts/sub/a.bom"))
        XCTAssertFalse(ProtectedPaths.isInstallerReceipt("/private/var/db/dslocal/a.bom"))
        XCTAssertFalse(ProtectedPaths.isInstallerReceipt("/tmp/receipts/a.bom"))
    }

    /// The rule's own pattern must not be able to reach a sibling directory
    /// even if the deny list were somehow bypassed.
    func testReceiptRulePatternCannotEscapeTheDirectory() {
        let rule = RuleIndex().rule(for: "uninstall.installerReceipt")!
        XCTAssertTrue(rule.pattern.matches("/private/var/db/receipts/com.acme.pkg.bom"))
        XCTAssertFalse(rule.pattern.matches("/private/var/db/dslocal"))
        XCTAssertFalse(rule.pattern.matches("/private/var/db/receipts"))
        XCTAssertFalse(rule.pattern.matches("/private/var/db/receipts/sub/a.bom"))
        XCTAssertTrue(rule.requiresPrivilege)
        XCTAssertFalse(rule.autoSelectable)
    }
}

/// Prefix matching is what took uninstall coverage from roughly a quarter of
/// what is on disk to nearly all of it. It is also the change most able to
/// claim files belonging to a different app, so the boundaries are pinned here.
final class UninstallNameMatchingTests: XCTestCase {
    private let id = "com.acme.Editor"

    func testMatchesTheIdentifierAndItsExtensions() {
        for name in [
            "com.acme.Editor",                        // the identifier itself
            "com.acme.Editor.plist",                  // preferences
            "com.acme.Editor.savedState",             // window state
            "com.acme.Editor.binarycookies",          // cookie jar
            "com.acme.Editor.FinderSync",             // an extension's container
            "com.acme.Editor.helper",                 // a helper tool
            "ABCDE12345.com.acme.Editor",             // team-prefixed group container
            "ABCDE12345.com.acme.Editor.shared",
            "group.com.acme.Editor",                  // literal group prefix
            "group.com.acme.Editor.shared",
            "GROUP.COM.ACME.EDITOR",                  // vendors are inconsistent about case
        ] {
            XCTAssertTrue(
                AppUninstallPlanner.name(name, belongsTo: id),
                "\(name) belongs to \(id)"
            )
        }
    }

    /// The expensive direction: claiming a neighbour's files.
    func testDoesNotClaimNeighbours() {
        for name in [
            "com.acme.EditorPro",                     // longer name, same stem
            "com.acme.EditorPro.plist",
            "com.acme.Edit",                          // shorter
            "com.acme.Viewer",                        // sibling product
            "com.other.Editor",                       // different vendor
            "notateam.com.acme.Editor",               // prefix is not a team id
            "ABCDE1234.com.acme.Editor",              // nine chars, not a team id
            "groups.com.acme.Editor",                 // not the literal `group` prefix
            "group.com.acme.EditorPro",               // group prefix, wrong app
        ] {
            XCTAssertFalse(
                AppUninstallPlanner.name(name, belongsTo: id),
                "\(name) must not be claimed by \(id)"
            )
        }
    }

    /// A real app on the test machine ships `st` as its whole bundle
    /// identifier. Prefix-matching that would claim `st.anything` across the
    /// system, so short and dotless identifiers get exact matches only.
    func testShortOrDotlessIdentifiersMatchExactlyOnly() {
        XCTAssertTrue(AppUninstallPlanner.name("st", belongsTo: "st"))
        XCTAssertTrue(AppUninstallPlanner.name("st.plist", belongsTo: "st"))
        XCTAssertFalse(AppUninstallPlanner.name("st.something.else", belongsTo: "st"))
        XCTAssertFalse(AppUninstallPlanner.name("com.apple.Stickies", belongsTo: "st"))

        XCTAssertTrue(AppUninstallPlanner.name("Notion", belongsTo: "Notion"))
        XCTAssertFalse(AppUninstallPlanner.name("Notion.helper", belongsTo: "Notion"))
    }
}

final class AppUninstallPlannerTests: XCTestCase {

    /// The planner grants nothing on its own — every path it proposes is tagged
    /// with a rule that already exists in the catalog, and `RuleEngine` derives
    /// permission from that. A renamed rule would make the uninstaller silently
    /// propose items the engine then denies as `unknownRule`, which reads to the
    /// user as "the feature is broken" rather than "a rule moved".
    func testEveryRuleThePlannerEmitsExistsInTheCatalog() {
        let emitted = [
            "uninstall.appBundle",
            "uninstall.userAppBundle",
            "residue.applicationSupport",
            "residue.containers",
            "residue.groupContainers",
            "residue.preferences",
            "residue.preferencesByHost",
            "residue.savedState",
            "residue.httpStorages",
            "residue.webkit",
            "residue.logs",
            "residue.launchAgents",
            "residue.applicationScripts",
            "uninstall.installerReceipt",
            "residue.systemLaunchAgents",
            "residue.systemLaunchDaemons",
            "residue.privilegedHelpers",
            "cache.userCaches",
        ]
        let index = RuleIndex()
        for id in emitted {
            XCTAssertNotNil(index.rule(for: id), "planner emits \(id) but the catalog has no such rule")
        }
    }

    /// The bundle rules must cover a real bundle path and nothing above it.
    func testBundleRulePatternsMatchOnlyBundles() {
        let index = RuleIndex()
        let system = index.rule(for: "uninstall.appBundle")!
        XCTAssertTrue(system.pattern.matches("/Applications/Acme.app"))
        XCTAssertFalse(system.pattern.matches("/Applications"))
        XCTAssertFalse(system.pattern.matches("/Applications/Acme.app/Contents"))
        XCTAssertFalse(system.pattern.matches("/Applications/Suite/Acme.app"))

        let user = index.rule(for: "uninstall.userAppBundle")!
        XCTAssertTrue(user.pattern.matches("\(PathRedaction.home)/Applications/Acme.app"))
        XCTAssertFalse(user.pattern.matches("/Applications/Acme.app"))
    }

    /// Neither bundle rule may be auto-selectable. Removing an application is
    /// not something a heuristic gets to pre-tick.
    func testBundleRulesAreNeverAutoSelectable() {
        let index = RuleIndex()
        for id in ["uninstall.appBundle", "uninstall.userAppBundle"] {
            let rule = index.rule(for: id)!
            XCTAssertFalse(rule.autoSelectable, "\(id) must not be auto-selectable")
            XCTAssertFalse(rule.rebuildable, "\(id) is not rebuildable")
        }
    }

    /// Sandbox containers hold the app's own documents. They must never be
    /// pre-ticked, however confident the rest of the plan is.
    func testUserDataKindsAreFlagged() {
        XCTAssertTrue(AppUninstallPlanner.Kind.container.carriesUserData)
        XCTAssertTrue(AppUninstallPlanner.Kind.support.carriesUserData)
        XCTAssertFalse(AppUninstallPlanner.Kind.cache.carriesUserData)
        XCTAssertFalse(AppUninstallPlanner.Kind.bundle.carriesUserData)
    }

    /// The uninstall category is driven by an explicit choice of app and must
    /// stay out of the sweep, or a scan would start proposing app removals.
    func testUninstallIsNotASweepCategory() {
        XCTAssertFalse(ScanCategory.appUninstall.isSweepCategory)
        XCTAssertFalse(ScanCategory.sweepCategories.contains(.appUninstall))
        XCTAssertEqual(ScanCategory.sweepCategories.count, ScanCategory.allCases.count - 1)
    }
}
