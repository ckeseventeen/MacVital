import XCTest
@testable import MacVitalKit

/// These are the tests that matter. Everything else in this app is a feature;
/// this is the part where a mistake costs somebody their data.
final class RuleEngineTests: XCTestCase {

    private var sandbox: URL!
    private var engine: RuleEngine!
    private var rules: RuleIndex!

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacVitalTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)

        rules = RuleIndex(rules: RuleCatalog.all + [testRule])
        engine = RuleEngine(
            rules: rules,
            processIndex: RunningProcessIndex(entries: []),
            selfProtectedPrefixes: ["\(PathRedaction.home)/Library/Application Support/MacVital"]
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: sandbox)
    }

    /// A permissive rule scoped to the temp sandbox, so we can exercise the
    /// guards without touching anything real.
    private var testRule: CleanupRule {
        CleanupRule(
            id: "test.sandbox",
            category: .caches,
            pattern: "/**",
            kind: "测试",
            rationale: "测试用规则",
            allowedInUserData: true
        )
    }

    private func item(at url: URL, ruleID: String = "test.sandbox", isDirectory: Bool = false) -> ScanItem {
        ScanItem(
            path: url.path,
            category: .caches,
            ruleID: ruleID,
            kindHint: "测试",
            sizeBytes: 1024,
            isDirectory: isDirectory
        )
    }

    // MARK: - Default deny

    func testUnknownRuleIsDenied() throws {
        let file = sandbox.appendingPathComponent("a.txt")
        try Data("x".utf8).write(to: file)

        let decision = engine.evaluate(item(at: file, ruleID: "no.such.rule"))
        XCTAssertEqual(decision.admission, .deny)
        XCTAssertEqual(decision.denyReason, .unknownRule)
    }

    func testMissingPathIsDenied() {
        let decision = engine.evaluate(item(at: sandbox.appendingPathComponent("gone.txt")))
        XCTAssertEqual(decision.denyReason, .missing)
    }

    // MARK: - Protected paths

    func testSystemPathsAreDenied() {
        for path in ["/System/Library/CoreServices/Finder.app", "/bin/sh", "/usr/lib/dyld"] {
            let decision = engine.evaluate(item(at: URL(fileURLWithPath: path)))
            XCTAssertEqual(decision.admission, .deny, "expected deny for \(path)")
        }
    }

    func testHomeAndVolumeRootsAreDenied() {
        let home = URL(fileURLWithPath: PathRedaction.home)
        XCTAssertEqual(engine.evaluate(item(at: home)).admission, .deny)
        XCTAssertEqual(engine.evaluate(item(at: URL(fileURLWithPath: "/Users"))).admission, .deny)
        XCTAssertEqual(engine.evaluate(item(at: URL(fileURLWithPath: "/"))).admission, .deny)
    }

    func testShallowPathsAreDenied() {
        let decision = engine.evaluate(item(at: URL(fileURLWithPath: "/opt/somedir")))
        XCTAssertEqual(decision.denyReason, .pathTooShallow)
    }

    /// The structural deny list must not be conditional on the filesystem. A
    /// protected path answers "protected" whether or not it happens to exist —
    /// otherwise the verdict for the same rule changes with the state of the
    /// disk, and a protected path that is briefly absent reads as merely gone.
    func testProtectedPathsAreDeniedWithoutConsultingTheFilesystem() {
        let cases: [(String, DenyReason)] = [
            ("\(PathRedaction.home)/Library/Keychains/does-not-exist.keychain-db", .criticalPath),
            ("\(PathRedaction.home)/.ssh/does-not-exist", .criticalPath),
            ("/System/Library/NoSuchThing", .criticalPath),
            ("/opt/nothing-here", .pathTooShallow),
        ]
        for (path, expected) in cases {
            XCTAssertFalse(FileManager.default.fileExists(atPath: path), "fixture must not exist: \(path)")
            XCTAssertEqual(
                engine.evaluate(item(at: URL(fileURLWithPath: path))).denyReason,
                expected,
                "expected \(expected) for \(path)"
            )
        }
    }

    /// The self-protection prefixes are compared against realpath-resolved
    /// candidates, so they have to survive the same normalisation. A prefix
    /// given as /var/... must still cover its own /private/var/... contents.
    func testSelfProtectionSurvivesFirmlinkNormalisation() throws {
        let quarantine = sandbox.appendingPathComponent("Quarantine", isDirectory: true)
        let inside = quarantine.appendingPathComponent("Items/abc", isDirectory: true)
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)

        // Feed the prefix in unnormalised form on purpose — the temp directory
        // is reached through /var, while realpath resolves it to /private/var.
        let unnormalized = quarantine.path.replacingOccurrences(of: "/private/var/", with: "/var/")
        let selfAware = RuleEngine(
            rules: rules,
            processIndex: RunningProcessIndex(entries: []),
            selfProtectedPrefixes: [unnormalized]
        )
        XCTAssertEqual(selfAware.evaluate(item(at: inside, isDirectory: true)).denyReason, .selfProtection)
    }

    func testKeychainDirectoryIsDenied() {
        let path = URL(fileURLWithPath: "\(PathRedaction.home)/Library/Keychains/login.keychain-db")
        XCTAssertEqual(engine.evaluate(item(at: path)).admission, .deny)
    }

    /// Documents is off limits unless the rule opts in — and the opt-in only
    /// exists for build output like node_modules.
    func testUserDataRequiresRuleOptIn() throws {
        let protectedPaths = ProtectedPaths()
        XCTAssertTrue(protectedPaths.isInSensitiveUserData("\(PathRedaction.home)/Documents/taxes.pdf"))
        XCTAssertTrue(protectedPaths.isInSensitiveUserData("\(PathRedaction.home)/Desktop/x/y"))
        XCTAssertFalse(protectedPaths.isInSensitiveUserData("\(PathRedaction.home)/Library/Caches/foo"))

        let strictRule = CleanupRule(
            id: "test.strict",
            category: .caches,
            pattern: "/**",
            kind: "测试",
            rationale: "不允许进入用户数据目录",
            allowedInUserData: false
        )
        let strictEngine = RuleEngine(
            rules: RuleIndex(rules: [strictRule]),
            processIndex: RunningProcessIndex(entries: [])
        )
        let documents = URL(fileURLWithPath: "\(PathRedaction.home)/Documents")
        // Only assert when Documents actually exists on the test machine.
        if FileManager.default.fileExists(atPath: documents.path) {
            let target = documents.appendingPathComponent("MacVitalTestProbe")
            try? FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: target) }

            let decision = strictEngine.evaluate(item(at: target, ruleID: "test.strict", isDirectory: true))
            XCTAssertEqual(decision.denyReason, .protectedUserData)
        }
    }

    // MARK: - Symlinks

    func testSymlinkIsRefusedRatherThanFollowed() throws {
        let target = sandbox.appendingPathComponent("real.txt")
        try Data("payload".utf8).write(to: target)
        let link = sandbox.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let decision = engine.evaluate(item(at: link))
        XCTAssertEqual(decision.denyReason, .symlinkEscape)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }

    // MARK: - Pattern re-validation

    func testPathMustMatchTheClaimingRule() throws {
        let file = sandbox.appendingPathComponent("b.txt")
        try Data("x".utf8).write(to: file)

        // Claim a rule whose pattern cannot possibly cover a temp path.
        let decision = engine.evaluate(item(at: file, ruleID: "dev.xcode.derivedData"))
        XCTAssertEqual(decision.denyReason, .patternMismatch)
    }

    // MARK: - In-use detection

    func testRunningProcessBlocksRemoval() throws {
        let directory = sandbox.appendingPathComponent("app", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let binary = directory.appendingPathComponent("tool")
        try Data("#!/bin/sh\n".utf8).write(to: binary)

        let busyEngine = RuleEngine(
            rules: rules,
            processIndex: RunningProcessIndex(entries: [
                .init(pid: 4242, executablePath: binary.path, bundleIdentifier: nil, localizedName: "Tool")
            ])
        )
        let decision = busyEngine.evaluate(item(at: directory, isDirectory: true))
        XCTAssertEqual(decision.denyReason, .inUse)
        XCTAssertTrue(decision.rationale.contains("4242"))
    }

    func testRunningAppBundleIDBlocksRemoval() throws {
        let directory = sandbox.appendingPathComponent("container", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let busyEngine = RuleEngine(
            rules: rules,
            processIndex: RunningProcessIndex(entries: [
                .init(pid: 1, executablePath: "/Applications/Acme.app/Contents/MacOS/Acme",
                      bundleIdentifier: "com.acme.editor", localizedName: "Acme")
            ])
        )
        var busyItem = item(at: directory, isDirectory: true)
        busyItem.ownerHint = OwnerHint(bundleIdentifier: "com.acme.editor", appName: "Acme")

        XCTAssertEqual(busyEngine.evaluate(busyItem).denyReason, .inUse)
    }

    // MARK: - Self protection

    func testQuarantineStoreIsNeverRemovable() throws {
        let quarantine = sandbox.appendingPathComponent("Quarantine", isDirectory: true)
        try FileManager.default.createDirectory(at: quarantine, withIntermediateDirectories: true)
        let inside = quarantine.appendingPathComponent("Items", isDirectory: true)
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)

        let selfAware = RuleEngine(
            rules: rules,
            processIndex: RunningProcessIndex(entries: []),
            selfProtectedPrefixes: [quarantine.path]
        )
        XCTAssertEqual(selfAware.evaluate(item(at: inside, isDirectory: true)).denyReason, .selfProtection)
    }

    // MARK: - Happy path

    func testOrdinaryFileInSandboxIsAllowed() throws {
        let file = sandbox.appendingPathComponent("ok.txt")
        try Data("x".utf8).write(to: file)

        let decision = engine.evaluate(item(at: file))
        XCTAssertEqual(decision.admission, .allow)
        XCTAssertNil(decision.denyReason)
    }

    // MARK: - Catalog invariants

    func testCatalogHasUniqueRuleIDs() {
        let ids = RuleCatalog.all.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "duplicate rule IDs would silently shadow each other")
    }

    /// Only rules whose artifacts are unambiguously build output may reach
    /// into Documents / Desktop. If this list grows, it should be deliberate.
    func testUserDataOptInIsNarrow() {
        let optedIn = Set(RuleCatalog.all.filter(\.allowedInUserData).map(\.id))
        XCTAssertEqual(optedIn, [
            "dev.project.nodeModules",
            "dev.project.pods",
            "dev.project.swiftBuild",
            "dev.project.cargoTarget",
            "dev.project.pythonVenv",
            "dev.project.nextCache",
            "file.large",
            "file.duplicate",
        ])
    }

    /// Every rule that asks for root must live in one of a small, enumerated
    /// set of system roots. The point is not the list itself — it is that
    /// adding a privileged rule somewhere new has to be a deliberate edit to
    /// this test, not something that slips in with a feature.
    func testPrivilegedRulesLiveOnlyInApprovedSystemRoots() {
        let approvedRoots = [
            "/Library/",
            // Installer receipts. Reachable only through the single named
            // exemption in `ProtectedPaths.isInstallerReceipt`.
            "/private/var/db/receipts/",
        ]
        for rule in RuleCatalog.all where rule.requiresPrivilege {
            XCTAssertTrue(
                approvedRoots.contains { rule.pattern.raw.hasPrefix($0) },
                "\(rule.id) needs privilege but its pattern \(rule.pattern.raw) is not under an approved system root"
            )
            // Nothing privileged may ever point into the user's home: those
            // paths are writable without root, so a privilege requirement there
            // would mean the pattern is wrong.
            XCTAssertFalse(
                rule.pattern.raw.hasPrefix("~"),
                "\(rule.id) is privileged but points into the home directory"
            )
        }
    }
}

/// Guards on the shape of the catalog itself.
///
/// The premise of this file is that reading a rule's pattern tells you the
/// complete set of paths it can ever authorise. A wildcard that swallows a
/// whole tree breaks that premise silently — and did: a plug-in rule shipped
/// with `~/Library/**`, which authorises every path under Library, on the
/// reasoning that the planner only ever produced plug-in paths. That is a
/// property of today's caller, not of the catalog.
extension RuleEngineTests {

    /// Patterns whose breadth is deliberate, each for a stated reason.
    private static let approvedBroadPatterns: Set<String> = [
        // The user-file scanners produce paths anywhere the user keeps files;
        // narrowing these would mean enumerating the whole home directory.
        // Both are `autoSelectable: false` and their categories require
        // item-by-item approval.
        "~/**",
        // Empty folders, restricted to Library and never auto-selected.
        "~/Library/**",
    ]

    func testRulePatternsAreNotBroaderThanNecessary() {
        for rule in RuleCatalog.all {
            let raw = rule.pattern.raw
            guard raw.hasSuffix("/**") else { continue }
            guard !Self.approvedBroadPatterns.contains(raw) else { continue }

            // A `**` deeper in the tree is fine — `~/Library/Caches/Yarn/**`
            // still names exactly one directory. What is not fine is a `**`
            // hanging directly off a top-level root.
            let components = raw.split(separator: "/").dropLast()
            XCTAssertGreaterThanOrEqual(
                components.count, 3,
                "\(rule.id) uses \(raw), which authorises far more than it needs to"
            )
        }
    }

    /// Every generated plug-in rule names exactly one directory.
    func testPluginRulesNameASingleDirectory() {
        XCTAssertFalse(RuleCatalog.pluginResidue.isEmpty)
        for rule in RuleCatalog.pluginResidue {
            XCTAssertTrue(
                rule.pattern.raw.hasSuffix("/*"),
                "\(rule.id) should match one directory's direct children, not \(rule.pattern.raw)"
            )
            XCTAssertFalse(rule.pattern.raw.contains("**"), "\(rule.id) must not recurse")
            XCTAssertFalse(rule.autoSelectable, "\(rule.id) must not auto-select")
        }
    }

    /// Rule ids have to be unique — `RuleIndex` keys on them, and a duplicate
    /// would silently shadow whichever came second.
    func testRuleIDsAreUnique() {
        let ids = RuleCatalog.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "duplicate rule ids: \(Dictionary(grouping: ids) { $0 }.filter { $0.value.count > 1 }.keys)")
    }
}
