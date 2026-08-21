import XCTest
@testable import MacVitalKit

/// The invariant that matters most in this app, checked against the machine it
/// is running on: **nothing belonging to an installed app may be reported as
/// the residue of an uninstalled one.**
///
/// Two independent pieces of code answer "who owns this path".
/// `AppUninstallPlanner` answers it when the user names an app, and
/// `InstalledAppIndex.match` answers it when the scanner sweeps a directory.
/// They are allowed to differ in coverage. They are not allowed to disagree
/// about ownership — and they did: shared containers are named
/// `group.<bundleid>`, the planner understood that from the beginning, the
/// matcher did not. `group.com.nebula.karing` came back "no installed app owns
/// this" while Karing was installed and running, so its settings were offered
/// for deletion, repeatedly.
///
/// This test cannot be written against a fixture, because the bug was a
/// disagreement about real naming conventions. It reads the actual machine and
/// fails on any overlap.
final class InstalledAppNotResidueTests: XCTestCase {

    /// Paths the residue scanner would call unattributed.
    private func residueVerdict(for name: String, index: InstalledAppIndex) -> Bool {
        switch index.match(residueName: name) {
        case .installed, .nameSimilar:
            return false
        case .vendorInstalled, .none:
            // `.vendorInstalled` still reaches the user as a finding, only
            // flagged "同厂商仍在使用". `.none` is reported outright.
            return true
        }
    }

    func testNothingOwnedByAnInstalledAppIsReportedAsResidue() throws {
        let index = InstalledAppIndex.build()
        try XCTSkipIf(index.apps.isEmpty, "no installed apps to check against")

        let planner = AppUninstallPlanner()
        var violations: [(app: String, path: String)] = []

        for app in index.apps where app.path.hasPrefix("/Applications/") {
            for candidate in planner.plan(for: app) {
                let name = (candidate.item.path as NSString).lastPathComponent
                // Only the directories the residue sweep actually walks.
                let parent = (candidate.item.path as NSString).deletingLastPathComponent
                guard Self.residueRoots.contains(parent) else { continue }
                // The bundle itself is never swept as residue.
                guard candidate.kind != .bundle else { continue }

                if residueVerdict(for: name, index: index) {
                    violations.append((app.name, candidate.item.path))
                }
            }
        }

        XCTAssertTrue(
            violations.isEmpty,
            "installed apps' own files would be reported as residue:\n"
            + violations.map { "  \($0.app) → \(PathRedaction.abbreviate($0.path))" }.joined(separator: "\n")
        )
    }

    private static var residueRoots: Set<String> {
        let home = PathRedaction.home
        return [
            "\(home)/Library/Application Support",
            "\(home)/Library/Containers",
            "\(home)/Library/Group Containers",
            "\(home)/Library/Application Scripts",
            "\(home)/Library/Caches",
            "\(home)/Library/Preferences",
            "\(home)/Library/Saved Application State",
            "\(home)/Library/HTTPStorages",
            "\(home)/Library/WebKit",
            "\(home)/Library/Logs",
        ]
    }

    /// The same question asked directly of every shared container on this
    /// machine, since that is the shape that broke.
    func testEveryGroupContainerOfAnInstalledAppIsAttributed() throws {
        let index = InstalledAppIndex.build()
        let root = "\(PathRedaction.home)/Library/Group Containers"
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [])
            .filter { !$0.hasPrefix(".") }
        try XCTSkipIf(names.isEmpty, "no group containers on this machine")

        var unattributed: [String] = []
        for name in names {
            // Apple's own are excluded from the sweep by prefix already.
            guard !name.lowercased().contains("com.apple") else { continue }
            guard let inner = InstalledAppIndex.strippedContainerPrefix(name.lowercased()) else { continue }
            // Only assert about containers whose identifier names an app that
            // is actually installed — the rest are genuine leftovers.
            guard index.apps.contains(where: {
                inner == $0.bundleIdentifier.lowercased()
                    || inner.hasPrefix($0.bundleIdentifier.lowercased() + ".")
            }) else { continue }

            if residueVerdict(for: name, index: index) { unattributed.append(name) }
        }

        XCTAssertTrue(
            unattributed.isEmpty,
            "shared containers of installed apps left unattributed: \(unattributed)"
        )
    }
}
