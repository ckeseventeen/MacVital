import XCTest
@testable import MacVitalKit

/// The three-way intersection. Each test removes exactly one of the three
/// inputs and asserts the item stops being pre-selected.
final class CleanPlanTests: XCTestCase {

    private let rules = RuleIndex()

    private func finding(
        ruleID: String = "dev.xcode.derivedData",
        admission: Admission = .allow,
        recommendation: AIRecommendation? = .safeToRemove,
        confidence: Double = 0.9,
        category: ScanCategory = .developerResidue
    ) -> Finding {
        let item = ScanItem(
            path: "\(PathRedaction.home)/Library/Developer/Xcode/DerivedData/App-abc",
            category: category,
            ruleID: ruleID,
            kindHint: "DerivedData",
            sizeBytes: 5_000_000,
            isDirectory: true,
            rebuildable: true
        )
        let decision = RuleDecision(
            admission: admission,
            ruleID: ruleID,
            denyReason: admission == .deny ? .criticalPath : nil,
            rationale: "test"
        )
        let assessment = recommendation.map {
            AIAssessment(
                itemID: item.id,
                confidence: confidence,
                whatItIs: "x",
                consequence: "y",
                recommendation: $0,
                source: .heuristic
            )
        }
        return Finding(item: item, decision: decision, assessment: assessment)
    }

    func testAllThreeInputsAgreeMeansPreSelected() {
        let f = finding()
        XCTAssertEqual(CleanPlanBuilder.defaultSelection(for: [f], rules: rules), [f.id])
    }

    func testRuleEngineDenialRemovesItRegardlessOfConfidence() {
        let f = finding(admission: .deny, recommendation: .safeToRemove, confidence: 1.0)
        XCTAssertTrue(CleanPlanBuilder.defaultSelection(for: [f], rules: rules).isEmpty)
    }

    func testModelUncertaintyLeavesItUnchecked() {
        let low = finding(confidence: 0.4)
        XCTAssertTrue(CleanPlanBuilder.defaultSelection(for: [low], rules: rules).isEmpty)

        let review = finding(recommendation: .reviewFirst, confidence: 0.99)
        XCTAssertTrue(CleanPlanBuilder.defaultSelection(for: [review], rules: rules).isEmpty)
    }

    func testNonAutoSelectableRuleIsNeverPreChecked() {
        // Archives are admissible but not rebuildable, so the rule opts out.
        let f = finding(ruleID: "dev.xcode.archives")
        XCTAssertTrue(CleanPlanBuilder.defaultSelection(for: [f], rules: rules).isEmpty)
    }

    func testLargeAndDuplicateFilesAlwaysRequireManualSelection() {
        for category in [ScanCategory.largeFiles, .duplicateFiles] {
            let f = finding(
                ruleID: category == .largeFiles ? "file.large.downloads" : "file.duplicate.downloads",
                recommendation: .safeToRemove,
                confidence: 1.0,
                category: category
            )
            XCTAssertTrue(
                CleanPlanBuilder.defaultSelection(for: [f], rules: rules).isEmpty,
                "\(category.rawValue) must never be pre-selected"
            )
        }
    }

    /// With no advisor configured at all, a rule marked auto-selectable still
    /// stands on its own — the app must be usable fully offline.
    func testNoAssessmentFallsBackToTheRuleAlone() {
        let f = finding(recommendation: nil)
        XCTAssertEqual(CleanPlanBuilder.defaultSelection(for: [f], rules: rules), [f.id])
    }

    func testAssessmentIsClampedToUnitRange() {
        let over = AIAssessment(
            itemID: UUID(), confidence: 4.2, whatItIs: "", consequence: "",
            recommendation: .safeToRemove, source: .cloud
        )
        XCTAssertEqual(over.confidence, 1.0)

        let under = AIAssessment(
            itemID: UUID(), confidence: -1, whatItIs: "", consequence: "",
            recommendation: .keep, source: .cloud
        )
        XCTAssertEqual(under.confidence, 0.0)
    }
}

final class PathRedactionTests: XCTestCase {
    func testHomeIsAbbreviated() {
        let path = "\(PathRedaction.home)/Library/Caches/foo"
        XCTAssertEqual(PathRedaction.abbreviate(path), "~/Library/Caches/foo")
    }

    func testUsernameIsScrubbedFromOtherUsersPaths() {
        let redacted = PathRedaction.redact("/Users/someoneelse/Documents/x")
        XCTAssertEqual(redacted, "/Users/<user>/Documents/x")
    }

    func testRedactedPathNeverContainsShortUsername() {
        guard !PathRedaction.userName.isEmpty else { return }
        let path = "\(PathRedaction.home)/Projects/\(PathRedaction.userName)-notes/x"
        XCTAssertFalse(PathRedaction.redact(path).contains(PathRedaction.userName))
    }
}

final class InstalledAppIndexTests: XCTestCase {
    private let index = InstalledAppIndex(apps: [
        .init(bundleIdentifier: "com.acme.Editor", name: "Acme Editor", path: "/Applications/Acme Editor.app")
    ])

    func testExactBundleIDMatches() {
        guard case .installed = index.match(residueName: "com.acme.Editor.plist") else {
            return XCTFail("expected installed match")
        }
    }

    /// An identifier hanging off an installed app's own identifier is that
    /// app's — its updater, its extension, its helper.
    ///
    /// This used to assert `.vendorInstalled`, which still reaches the user as
    /// a finding. The assertion was wrong, and a machine-wide audit showed what
    /// it cost: Gemini's launcher, Claude's ShipIt cache, WPS's Finder
    /// extension, nine Safari extensions and UURemote's helper were all listed
    /// as the residue of uninstalled apps, while every one of those apps sat in
    /// /Applications. There is nothing ambiguous about `com.acme.Editor.Updater`
    /// while `com.acme.Editor` is installed.
    func testIdentifierHangingOffAnInstalledAppBelongsToIt() {
        guard case .installed(let app) = index.match(residueName: "com.acme.Editor.Updater") else {
            return XCTFail("expected the extension to attribute to its app")
        }
        XCTAssertEqual(app.bundleIdentifier, "com.acme.Editor")
    }

    /// The genuinely ambiguous case, which must still be flagged rather than
    /// silently kept or silently removed: the *vendor* is installed, but this
    /// exact identifier is not any app — a shared component, or a helper from
    /// something since uninstalled.
    func testVendorPrefixIsStillFlagged() {
        guard case .vendorInstalled = index.match(residueName: "com.acme.OldThing") else {
            return XCTFail("expected vendor match")
        }
    }

    func testUnrelatedIdentifierIsAnOrphan() {
        guard case .none = index.match(residueName: "com.other.Thing.plist") else {
            return XCTFail("expected no match")
        }
    }

    func testExtensionStripping() {
        XCTAssertEqual(InstalledAppIndex.identifierToken(from: "com.a.b.savedState"), "com.a.b")
        XCTAssertEqual(InstalledAppIndex.identifierToken(from: "com.a.b.plist"), "com.a.b")
        XCTAssertEqual(InstalledAppIndex.identifierToken(from: "com.a.b"), "com.a.b")
    }

    // MARK: - Plain-name directories

    /// Almost nothing under Application Support is named like a bundle
    /// identifier, and treating those directories as orphans is the one
    /// mistake in this app that destroys live data. Every case here was a real
    /// false positive: `~/Library/Application Support/Google` (742 MB of
    /// Chrome's profile) reported as the leftovers of an uninstalled app.
    func testVendorNamedDirectoriesAreNotOrphansWhileTheVendorIsInstalled() {
        let index = InstalledAppIndex(apps: [
            // `Bundle.object(forInfoDictionaryKey:)` returns the *localized*
            // CFBundleName, so this is the shape the index really sees on a
            // Chinese system: a display name that shares nothing with the
            // ASCII directory the app writes to.
            .init(bundleIdentifier: "com.baidu.BaiduNetdisk-mac", name: "百度网盘", path: "/Applications/BaiduNetdisk_mac.app"),
            .init(bundleIdentifier: "com.google.Chrome", name: "Chrome", path: "/Applications/Google Chrome.app"),
            .init(bundleIdentifier: "com.jetbrains.pycharm", name: "PyCharm", path: "/Applications/PyCharm.app"),
            .init(bundleIdentifier: "com.sublimetext.4", name: "Sublime Text", path: "/Applications/Sublime Text.app"),
        ])

        for name in [
            "Google",           // vendor word out of com.google.Chrome
            "Chrome",           // product word out of the same identifier
            "JetBrains",        // vendor word, app displays as PyCharm
            "baidunetdisk",     // only the .app filename and bundle id can match
            "BaiduNetdisk",     // same, different casing
            "Sublime Text 3",   // directory carries a version the app name drops
        ] {
            guard case .nameSimilar = index.match(residueName: name) else {
                return XCTFail("\(name) must not be reported as orphaned residue")
            }
        }
    }

    /// The other direction still has to work, or the feature reports nothing.
    func testUnrelatedPlainNameIsStillAnOrphan() {
        let index = InstalledAppIndex(apps: [
            .init(bundleIdentifier: "com.google.Chrome", name: "Google Chrome", path: "/Applications/Google Chrome.app")
        ])
        guard case .none = index.match(residueName: "SomeDeadVendor") else {
            return XCTFail("expected no match")
        }
    }

    /// Short tokens match half the disk. `com` in particular is the namespace
    /// component of every identifier on the machine.
    func testShortAndNamespaceTokensDoNotMatch() {
        let index = InstalledAppIndex(apps: [
            .init(bundleIdentifier: "com.acme.go", name: "Go", path: "/Applications/Go.app")
        ])
        for name in ["com", "go", "ai"] {
            guard case .none = index.match(residueName: name) else {
                return XCTFail("\(name) is too generic to attribute")
            }
        }
    }
}

// MARK: - Select all

/// `selectAll` and `defaultSelection` have to agree about
/// `requiresExplicitSelection`. They did not: the default selection skipped
/// those categories while the footer's 全选 swept them in, so one click
/// undid the guarantee the enum states outright.
extension CleanPlanTests {

    private func findings() -> [Finding] {
        [
            finding(category: .developerResidue),
            finding(category: .caches),
            finding(category: .largeFiles),
            finding(category: .duplicateFiles),
            finding(category: .emptyFolders),
        ]
    }

    func testGlobalSelectAllSkipsCategoriesNeedingApproval() {
        let all = findings()
        let selected = CleanPlanBuilder.selectAll(in: nil, findings: all)
        let categories = Set(all.filter { selected.contains($0.id) }.map(\.item.category))

        XCTAssertEqual(categories, [.developerResidue, .caches])
        for category in ScanCategory.allCases where category.requiresExplicitSelection {
            XCTAssertFalse(categories.contains(category), "\(category) must not be swept in globally")
        }
    }

    /// Scoping to one category *is* the individual approval: the user picked
    /// that list and is looking at it.
    func testScopedSelectAllMayIncludeThem() {
        let all = findings()
        let selected = CleanPlanBuilder.selectAll(in: .largeFiles, findings: all)
        let categories = Set(all.filter { selected.contains($0.id) }.map(\.item.category))

        XCTAssertEqual(categories, [.largeFiles])
    }

    func testSelectAllNeverPicksDeniedItems() {
        let denied = finding(admission: .deny, category: .caches)
        let selected = CleanPlanBuilder.selectAll(in: nil, findings: [denied])
        XCTAssertTrue(selected.isEmpty)
    }

    func testScopedSelectAllStillSkipsDeniedItems() {
        let denied = finding(admission: .deny, category: .largeFiles)
        let selected = CleanPlanBuilder.selectAll(in: .largeFiles, findings: [denied])
        XCTAssertTrue(selected.isEmpty)
    }
}
