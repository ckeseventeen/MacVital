import Foundation
import AppKit
import MacVitalKit

@MainActor
final class StartupViewModel: ObservableObject {
    struct Row: Identifiable {
        let item: LoginItem
        let decision: RuleDecision
        /// Built once, in `init`, and stored.
        ///
        /// This was a computed property, and `LoginItemScanner.scanItem(for:)`
        /// mints a fresh `ScanItem.id` on every call. So `rows.map(\.finding)`
        /// and `Set(rows.map(\.finding.id))` produced two disjoint sets of
        /// UUIDs, the coordinator's `findings.filter { selection.contains(…) }`
        /// matched nothing, and "停用" moved nothing while reporting success.
        let finding: Finding

        /// The process this job is running right now, if it is up. Resolved
        /// from the same snapshot the engine uses, so the two agree.
        let running: RunningProcess?

        struct RunningProcess: Equatable {
            var pid: pid_t
            var executablePath: String
        }

        var id: String { item.id }
        var isSelectable: Bool { !decision.isDenied }

        /// `KeepAlive` means launchd owns the process. Killing it is answered
        /// by launchd restarting it about a second later, and quarantining the
        /// plist does not change that either — the job stays loaded until the
        /// next login. So there is nothing to offer here but the truth.
        var stoppingWouldNotStick: Bool { item.keepAlive }

        var canStopNow: Bool { running != nil && !stoppingWouldNotStick }

        init(item: LoginItem, decision: RuleDecision, running: RunningProcess? = nil) {
            self.item = item
            self.decision = decision
            self.running = running
            self.finding = Finding(item: LoginItemScanner.scanItem(for: item), decision: decision)
        }
    }

    @Published private(set) var rows: [Row] = []
    @Published var selection: Set<String> = []
    @Published private(set) var isLoading = false
    @Published private(set) var isRemoving = false
    @Published private(set) var summary: String?
    @Published private(set) var stopMessage: String?
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
            // One snapshot for both questions: what the engine sees as in use,
            // and which of these jobs is up right now.
            let processes = RunningProcessIndex.snapshot()
            let engine = RuleEngine(
                rules: rules,
                processIndex: processes,
                selfProtectedPrefixes: [quarantineRoot]
            )
            return items.map { item in
                let running = item.program
                    .flatMap { processes.executingProcess(under: ProtectedPaths.normalize($0)) }
                    .map { Row.RunningProcess(pid: $0.pid, executablePath: $0.executablePath) }
                return Row(
                    item: item,
                    decision: engine.evaluate(LoginItemScanner.scanItem(for: item)),
                    running: running
                )
            }
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

    // MARK: - Stopping

    /// Stop the process a job is currently running.
    ///
    /// Separate from 停用, and neither replaces the other: quarantining the
    /// plist stops it starting *next* login, this stops it *now*. Doing only
    /// the first left the process running for the rest of the session, which
    /// the summary said out loud and could do nothing about.
    ///
    /// Returns false when it refused to go, so the caller can offer the
    /// harsher option.
    @discardableResult
    func stop(_ row: Row, force: Bool = false) async -> Bool {
        guard let running = row.running else { return true }
        let target = ProcessTerminator.Target.process(
            pid: running.pid,
            executablePath: running.executablePath,
            name: row.item.displayName
        )

        let outcome = force
            ? await ProcessTerminator.forceQuit(target)
            : await ProcessTerminator.quit(target)

        switch outcome {
        case .closed:
            stopMessage = "已结束「\(row.item.displayName)」。"
                + (row.isSelectable ? "它下次登录时仍会启动，除非一并停用。" : "")
            await reload()
            return true
        case .stillRunning:
            stopMessage = nil
            return false
        case .notPermitted:
            stopMessage = "「\(row.item.displayName)」由系统或其他用户运行，"
                + "MacVital 不以 root 运行，无法结束它。停用后下次开机不再启动。"
            return true
        }
    }

    func clearStopMessage() { stopMessage = nil }

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

        // One array, used for both arguments. Deriving the selection from a
        // second traversal is what broke this before.
        let findings = rows.filter { selection.contains($0.id) }.map(\.finding)
        let outcome = await environment.coordinator.execute(
            findings: findings,
            selection: Set(findings.map(\.id))
        )

        await environment.refreshQuarantine()

        var lines = ["已停用 \(outcome.removed.count) 项，配置已移入隔离区，可随时还原。"]
        if !outcome.skipped.isEmpty {
            lines.append("跳过 \(outcome.skipped.count) 项：" + outcome.skipped.prefix(2).map(\.reason).joined(separator: "；"))
        }
        // Only true for the ones that are actually still up; the row-level
        // 停止 button handles those, and says so for the ones it cannot.
        lines.append("已在运行的进程不会被终止——用每行的「停止」按钮结束它，或重新登录。")
        summary = lines.joined(separator: "\n")

        selection = []
        await reload()
    }
}
