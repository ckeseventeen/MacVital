import XCTest
@testable import MacVitalKit

/// What may be called "the leftovers of an uninstalled app".
///
/// A machine-wide audit of what the residue scanner actually proposed found
/// several files that belong to macOS itself, offered under the rationale
/// "归属的 App 已不在本机":
///
///   * `~/Library/Preferences/.GlobalPreferences.plist` — the system's locale,
///     language, interface style and measurement units, all in one file,
///   * its `ByHost` twin,
///   * `ContextStoreAgent.plist` and `TokenBucketRateLimiter.plist` — Apple
///     daemons that carry no `com.apple.` prefix for the name filter to catch,
///   * `~/Library/Logs/DiagnosticReports` and
///     `~/Library/Application Support/CrashReporter` — the crash machinery,
///   * every child of `~/Library/Caches/com.apple.helpd`, listed one by one,
///     including `Cache.db`, `Cache.db-wal` and `Cache.db-shm` as three
///     separate rows.
///
/// A name-based deny list cannot be made complete — that is why these checks
/// are structural instead.
final class ResidueAttributionTests: XCTestCase {

    private let protectedPaths = ProtectedPaths()
    private var home: String { PathRedaction.home }

    // MARK: - The global preference domain

    func testGlobalPreferencesIsHardDenied() {
        XCTAssertEqual(
            protectedPaths.isHardDenied("\(home)/Library/Preferences/.GlobalPreferences.plist"),
            .protectedUserData
        )
    }

    func testGlobalPreferencesByHostIsHardDenied() {
        XCTAssertEqual(
            protectedPaths.isHardDenied(
                "\(home)/Library/Preferences/ByHost/.GlobalPreferences.F73D1360-0A2A-5307-9118-485B2619AA3B.plist"
            ),
            .protectedUserData
        )
    }

    /// The deny is on the global domain, not on preferences in general — the
    /// residue feature would be pointless otherwise.
    func testOrdinaryPreferencesAreNotHardDenied() {
        XCTAssertNil(
            protectedPaths.isHardDenied("\(home)/Library/Preferences/com.example.Editor.plist")
        )
    }

    /// The engine is the gate that actually matters: even handed an item that
    /// claims a real rule, it must refuse.
    func testEngineRefusesTheGlobalPreferenceDomain() {
        let engine = RuleEngine(
            rules: RuleIndex(),
            processIndex: RunningProcessIndex(entries: [])
        )
        let item = ScanItem(
            path: "\(home)/Library/Preferences/.GlobalPreferences.plist",
            category: .appResidue,
            ruleID: "residue.preferences",
            kindHint: "偏好设置",
            sizeBytes: 1048,
            isDirectory: false
        )
        let decision = engine.evaluate(item)
        XCTAssertTrue(decision.isDenied)
        XCTAssertEqual(decision.denyReason, .protectedUserData)
    }

    // MARK: - Attribution requires an identifier

    func testBundleIdentifierShapes() {
        XCTAssertTrue(InstalledAppIndex.looksLikeBundleIdentifier("com.example.Editor"))
        XCTAssertTrue(InstalledAppIndex.looksLikeBundleIdentifier("com.example"))

        // The two Apple domains the audit caught: no dots, so nothing to
        // attribute them to.
        XCTAssertFalse(InstalledAppIndex.looksLikeBundleIdentifier("ContextStoreAgent"))
        XCTAssertFalse(InstalledAppIndex.looksLikeBundleIdentifier("TokenBucketRateLimiter"))

        // Dotfiles are system state, never an app's residue.
        XCTAssertFalse(InstalledAppIndex.looksLikeBundleIdentifier(".GlobalPreferences"))
        XCTAssertFalse(InstalledAppIndex.looksLikeBundleIdentifier("com.example."))
        XCTAssertFalse(InstalledAppIndex.looksLikeBundleIdentifier("Editor"))
        XCTAssertFalse(InstalledAppIndex.looksLikeBundleIdentifier(""))
    }

    /// LaunchServices is only ever asked about identifier-shaped names, and is
    /// only ever consulted to *suppress* a finding.
    func testLaunchServicesIsNotConsultedForPlainNames() {
        XCTAssertNil(InstalledAppIndex.launchServicesApp(for: "Google"))
        XCTAssertNil(InstalledAppIndex.launchServicesApp(for: ".GlobalPreferences"))
    }

    /// An identifier no app on earth claims must not resolve to something.
    func testUnknownIdentifierResolvesToNothing() {
        XCTAssertNil(
            InstalledAppIndex.launchServicesApp(for: "com.nonesuchvendor.definitely-not-installed-9f3a")
        )
    }

    // MARK: - System-owned roots are not swept

    /// These rules exist to give `AppUninstallPlanner` coverage of one app's
    /// files. Their directories belong to Apple, and sweeping the *contents* as
    /// residue is a category error the per-child name filter cannot catch,
    /// because the give-away is the parent.
    func testRulesRootedInAppleDirectoriesAreRecognisable() {
        let sweptRoots = RuleCatalog.appResidue.map {
            ($0.id, URL(fileURLWithPath: $0.pattern.literalPrefix).lastPathComponent)
        }
        let helpCache = sweptRoots.first { $0.0 == "residue.helpCache" }
        XCTAssertEqual(helpCache?.1, "com.apple.helpd")

        let crashReports = sweptRoots.first { $0.0 == "residue.crashReports" }
        XCTAssertEqual(crashReports?.1, "CrashReporter")
    }
}
