import Foundation
import AppKit
import MacVitalKit

@MainActor
final class UninstallViewModel: ObservableObject {
    struct Row: Identifiable {
        let candidate: AppUninstallPlanner.Candidate
        let decision: RuleDecision
        var id: UUID { candidate.id }
        var isSelectable: Bool { !decision.isDenied }

        var finding: Finding {
            Finding(item: candidate.item, decision: decision)
        }
    }

    @Published private(set) var apps: [InstalledAppIndex.App] = []
    @Published var query: String = ""
    @Published private(set) var selectedApp: InstalledAppIndex.App?
    @Published private(set) var rows: [Row] = []
    @Published var selection: Set<UUID> = []
    @Published private(set) var isPlanning = false
    @Published private(set) var isRemoving = false
    @Published var errorMessage: String?
    @Published private(set) var summary: String?

    private let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    var visibleApps: [InstalledAppIndex.App] {
        let trimmed = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return apps }
        return apps.filter {
            $0.name.lowercased().contains(trimmed) || $0.bundleIdentifier.lowercased().contains(trimmed)
        }
    }

    var selectedBytes: Int64 {
        rows.filter { selection.contains($0.id) }.reduce(0) { $0 + $1.candidate.item.sizeBytes }
    }

    var totalBytes: Int64 {
        rows.reduce(0) { $0 + $1.candidate.item.sizeBytes }
    }

    var deniedRows: [Row] { rows.filter { !$0.isSelectable } }

    var needsHelper: Bool {
        rows.contains { selection.contains($0.id) && $0.decision.admission == .allowWithPrivilege }
            && environment.helperStatus != .enabled
    }

    // MARK: - Loading

    func loadApps() {
        let index = InstalledAppIndex.build()
        let home = PathRedaction.home
        // Only what the user can actually remove: /Applications and
        // ~/Applications. Bundles under /System are SIP-protected and listing
        // them would offer a button that can never work.
        apps = index.apps
            .filter { $0.path.hasPrefix("/Applications/") || $0.path.hasPrefix("\(home)/Applications/") }
            .filter { $0.bundleIdentifier != HelperConstants.appBundleIdentifier }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func select(_ app: InstalledAppIndex.App) async {
        selectedApp = app
        rows = []
        selection = []
        summary = nil
        isPlanning = true
        defer { isPlanning = false }

        let rules = environment.rules
        let quarantineRoot = environment.quarantineRoot

        let planned: [Row] = await Task.detached(priority: .userInitiated) {
            let candidates = AppUninstallPlanner().plan(for: app)
            // Same engine, same catalog as every other removal path. The
            // uninstaller decides what to *propose*; permission is re-derived
            // here and again immediately before the move.
            let engine = RuleEngine(
                rules: rules,
                processIndex: RunningProcessIndex.snapshot(),
                selfProtectedPrefixes: [quarantineRoot]
            )
            return candidates.map { Row(candidate: $0, decision: engine.evaluate($0.item)) }
        }.value

        rows = planned
        // Pre-tick everything admissible except the pieces that carry user
        // data — a sandbox container is the app's documents, and losing those
        // by default is not a tradeoff to make on the user's behalf.
        selection = Set(
            planned
                .filter { $0.isSelectable && !$0.candidate.kind.carriesUserData }
                .map(\.id)
        )
    }

    func clearSelection() {
        selectedApp = nil
        rows = []
        selection = []
        summary = nil
    }

    // MARK: - Selection

    func toggle(_ row: Row) {
        guard row.isSelectable else { return }
        if selection.contains(row.id) { selection.remove(row.id) } else { selection.insert(row.id) }
    }

    func selectAll() {
        selection = Set(rows.filter(\.isSelectable).map(\.id))
    }

    func deselectAll() {
        selection = []
    }

    func revealInFinder(_ row: Row) {
        NSWorkspace.shared.activateFileViewerSelecting([row.candidate.item.url])
    }

    // MARK: - Execute

    func uninstall() async {
        guard !selection.isEmpty else { return }
        isRemoving = true
        defer { isRemoving = false }

        let outcome = await environment.coordinator.execute(
            findings: rows.map(\.finding),
            selection: selection
        )

        await environment.refreshQuarantine()

        var lines = ["已将 \(outcome.removed.count) 项移入隔离区，回收 \(ByteFormat.string(outcome.reclaimedBytes))。"]
        if !outcome.skipped.isEmpty {
            lines.append("跳过 \(outcome.skipped.count) 项：" + outcome.skipped.prefix(3).map(\.reason).joined(separator: "；"))
        }
        summary = lines.joined(separator: "\n")

        // Re-plan so the sheet shows what is actually left rather than a stale
        // list of paths that no longer exist.
        if let app = selectedApp {
            loadApps()
            await select(app)
        }
    }
}
