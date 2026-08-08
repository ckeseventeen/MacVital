import Foundation
import AppKit
import MacVitalKit

@MainActor
final class StartupViewModel: ObservableObject {
    struct Row: Identifiable {
        let item: LoginItem
        let decision: RuleDecision
        var id: String { item.id }
        var isSelectable: Bool { !decision.isDenied }
        var finding: Finding {
            Finding(item: LoginItemScanner.scanItem(for: item), decision: decision)
        }
    }

    @Published private(set) var rows: [Row] = []
    @Published var selection: Set<String> = []
    @Published private(set) var isLoading = false
    @Published private(set) var isRemoving = false
    @Published var errorMessage: String?
    @Published private(set) var summary: String?
    @Published var showOnlyOrphaned = false

    private let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    var visibleRows: [Row] {
        showOnlyOrphaned ? rows.filter { $0.item.isOrphaned } : rows
    }

    var orphanCount: Int { rows.filter { $0.item.isOrphaned }.count }

    var needsHelper: Bool {
        rows.contains { selection.contains($0.id) && $0.decision.admission == .allowWithPrivilege }
            && environment.helperStatus != .enabled
    }

    // MARK: - Load

    func reload() async {
        isLoading = true
        defer { isLoading = false }

        let rules = environment.rules
        let quarantineRoot = environment.quarantineRoot

        let loaded: [Row] = await Task.detached(priority: .userInitiated) {
            let items = LoginItemScanner().scan()
            let engine = RuleEngine(
                rules: rules,
                processIndex: RunningProcessIndex.snapshot(),
                selfProtectedPrefixes: [quarantineRoot]
            )
            return items.map { Row(item: $0, decision: engine.evaluate(LoginItemScanner.scanItem(for: $0))) }
        }.value

        rows = loaded
        // Nothing is pre-ticked. A startup item that looks dead to us may be
        // the thing the user's workflow depends on, and the orphan filter is
        // already one click away for the unambiguous cases.
        selection = []
    }

    // MARK: - Selection

    func toggle(_ row: Row) {
        guard row.isSelectable else { return }
        if selection.contains(row.id) { selection.remove(row.id) } else { selection.insert(row.id) }
    }

    func selectOrphaned() {
        selection = Set(rows.filter { $0.item.isOrphaned && $0.isSelectable }.map(\.id))
    }

    func deselectAll() { selection = [] }

    func reveal(_ row: Row) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: row.item.path)])
    }

    // MARK: - Disable

    /// "Disable" is a quarantine move, not `launchctl unload`. The job stops
    /// running from the next login, the plist is restorable for the whole
    /// retention window, and the operation goes through the same rule engine
    /// and privileged helper as every other removal.
    func disableSelected() async {
        guard !selection.isEmpty else { return }
        isRemoving = true
        defer { isRemoving = false }

        let targets = rows.filter { selection.contains($0.id) }
        let outcome = await environment.coordinator.execute(
            findings: targets.map(\.finding),
            selection: Set(targets.map(\.finding.id))
        )

        await environment.refreshQuarantine()

        var lines = ["已停用 \(outcome.removed.count) 项，配置已移入隔离区，可随时还原。"]
        if !outcome.skipped.isEmpty {
            lines.append("跳过 \(outcome.skipped.count) 项：" + outcome.skipped.prefix(2).map(\.reason).joined(separator: "；"))
        }
        lines.append("已在运行的进程不会被终止，重新登录后不再启动。")
        summary = lines.joined(separator: "\n")

        selection = []
        await reload()
    }
}
