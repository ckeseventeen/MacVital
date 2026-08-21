import Foundation
import AppKit
import MacVitalKit

@MainActor
final class UninstallViewModel: ObservableObject {
    struct Row: Identifiable {
        let candidate: AppUninstallPlanner.Candidate
        let decision: RuleDecision
        /// Stored rather than computed: SwiftUI re-evaluates row bodies
        /// constantly, and there is no reason to rebuild a value that cannot
        /// change. (`candidate.item` already carries a stable id, so unlike the
        /// startup list this was never wrong — only wasteful.)
        let finding: Finding

        var id: UUID { candidate.id }
        var isSelectable: Bool { !decision.isDenied }

        init(candidate: AppUninstallPlanner.Candidate, decision: RuleDecision) {
            self.candidate = candidate
            self.decision = decision
            self.finding = Finding(item: candidate.item, decision: decision)
        }
    }

    @Published private(set) var apps: [InstalledAppIndex.App] = []
    @Published var query: String = ""
    @Published private(set) var selectedApp: InstalledAppIndex.App?
    @Published private(set) var rows: [Row] = []
    @Published var selection: Set<UUID> = []
    @Published private(set) var isPlanning = false
    @Published private(set) var isRemoving = false
    @Published private(set) var summary: String?
    /// What a re-plan found still on disk after the removal ran.
    ///
    /// "卸载干净" is a claim about coverage, and coverage is the one thing the
    /// app cannot verify by reasoning about its own code. So it re-runs the
    /// planner afterwards and shows whatever is left — including nothing, which
    /// is the answer that makes the claim worth anything.
    @Published private(set) var leftovers: [Row] = []

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

    /// Rows locked only because something is still running. Unlike every other
    /// deny reason this one is temporary — the user can clear it — so the UI
    /// treats it separately instead of lumping it in with "protected forever".
    var inUseRows: [Row] { rows.filter { $0.decision.denyReason == .inUse } }

    /// The running instance of the app being uninstalled, if it is up.
    var runningInstance: NSRunningApplication? {
        guard let identifier = selectedApp?.bundleIdentifier else { return nil }
        return NSRunningApplication
            .runningApplications(withBundleIdentifier: identifier)
            .first { !$0.isTerminated }
    }

    /// Everything that would have to close for the plan to go through.
    ///
    /// Not just the app itself. An app's own helpers hold its files too — a
    /// Finder extension, an updater, a login-item daemon — and each carries its
    /// own bundle identifier, so quitting the main app left those rows locked
    /// and the reason unexplained. The engine now names whatever it found, and
    /// this collects them.
    var blockingTargets: [ProcessTerminator.Target] {
        var targets: [ProcessTerminator.Target] = []
        if let app = selectedApp, runningInstance != nil {
            targets.append(.application(bundleIdentifier: app.bundleIdentifier, name: app.name))
        }
        for row in inUseRows {
            guard let target = ProcessTerminator.target(for: row.decision) else { continue }
            guard !targets.contains(target) else { continue }
            targets.append(target)
        }
        return targets
    }

    /// Blocking targets whose lifetime launchd owns, named for the
    /// confirmation. Killing one of these accomplishes nothing that lasts —
    /// two of the daemons on the machine this was tested against carry
    /// `KeepAlive`, and both belong to apps this page offers to remove.
    var relaunchingBlockers: [String] {
        blockingTargets.compactMap { target in
            ProcessTerminator.relaunchingJob(for: target).map { "\(target.name)（\($0.label)）" }
        }
    }

    /// True when a graceful quit has been tried and something is still up, so
    /// the UI may offer the harsher option. Never true before that.
    @Published private(set) var quitWasRefused = false
    /// Targets a graceful quit could not close, named so the confirmation can
    /// say what is about to be killed.
    @Published private(set) var stubbornTargets: [String] = []

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
        leftovers = []
        await plan(for: app, preservingSelection: false)
    }

    /// Re-run the engine against the app already on screen.
    ///
    /// The process snapshot is taken when the plan is built, so a row locked
    /// with `.inUse` stays locked for as long as that plan lives — quitting the
    /// app changes nothing the user can see. That reads as the lock being
    /// permanent, which for this one reason it is not.
    func replan() async {
        guard let app = selectedApp, !isPlanning, !isRemoving else { return }
        await plan(for: app, preservingSelection: true)
    }

    /// Ask everything holding the app's files to quit, then re-evaluate.
    ///
    /// `terminate()` rather than `forceTerminate()`: the app gets to run its
    /// normal quit path and prompt about unsaved work. Killing an app outright
    /// to speed up its own uninstall would be a poor trade — that is what
    /// `forceQuitBlockersAndReplan` is for, and only once this has failed.
    @discardableResult
    func quitRunningInstanceAndReplan() async -> Bool {
        await close(force: false)
    }

    /// Kill what would not go quietly.
    ///
    /// Only ever called from a confirmation that names the processes, because
    /// this is the one action in the app that can lose work the user has not
    /// saved.
    @discardableResult
    func forceQuitBlockersAndReplan() async -> Bool {
        await close(force: true)
    }

    private func close(force: Bool) async -> Bool {
        let targets = blockingTargets
        guard !targets.isEmpty else {
            quitWasRefused = false
            stubbornTargets = []
            return true
        }

        var refused: [String] = []
        for target in targets {
            let outcome = force
                ? await ProcessTerminator.forceQuit(target)
                : await ProcessTerminator.quit(target)
            switch outcome {
            case .closed:
                continue
            case .stillRunning:
                refused.append(target.name)
            case .notPermitted:
                // Root-owned. The main process is not root by design, and the
                // privileged helper deliberately exposes no way to signal a
                // process — a root-level "kill anything" verb is not a surface
                // worth having for this.
                refused.append("\(target.name)（需要管理员权限，无法结束）")
            }
        }

        stubbornTargets = refused
        // Only a *graceful* refusal justifies offering the harsher button. If
        // force already failed, there is nothing further to escalate to.
        quitWasRefused = !force && !refused.isEmpty
        await replan()
        return refused.isEmpty
    }

    /// Quit the app and, if it actually went away, uninstall it.
    ///
    /// Splitting these into two clicks meant noticing the footer hint first,
    /// which is a thing to notice rather than a thing to do. The semantics are
    /// unchanged — the user still explicitly agrees to the quit, and it is
    /// still `terminate()`, so an app with unsaved work still gets to ask.
    ///
    /// If it does not quit — a modal sheet, an ignored terminate — the
    /// uninstall does not run. Proceeding anyway would delete files the app is
    /// about to rewrite on its own quit, which is the failure this whole check
    /// exists to prevent.
    func quitAndUninstall() async {
        let quit = await quitRunningInstanceAndReplan()
        guard quit else {
            let names = stubbornTargets.joined(separator: "、")
            summary = "\(names.isEmpty ? "该 App" : names) 没有退出，卸载已中止。"
                + (quitWasRefused ? "可以用「强制结束」直接结束它们，但未保存的内容会丢失。" : "请手动退出后重试。")
            leftovers = rows
            return
        }
        await uninstall()
    }

    /// Force-quit, then uninstall. Reached only from a confirmation.
    func forceQuitAndUninstall() async {
        let quit = await forceQuitBlockersAndReplan()
        guard quit else {
            let names = stubbornTargets.joined(separator: "、")
            summary = "仍有进程无法结束：\(names)。卸载已中止。"
            leftovers = rows
            return
        }
        await uninstall()
    }

    private func plan(for app: InstalledAppIndex.App, preservingSelection: Bool) async {
        isPlanning = true
        defer { isPlanning = false }

        let rules = environment.rules
        let quarantineRoot = environment.quarantineRoot

        // Keyed by path, not by `id`. `ScanItem.id` is a fresh `UUID()` on every
        // construction, so a re-plan produces entirely new identifiers and any
        // selection carried across by id would silently come back empty.
        let previouslySelected = Set(
            rows.filter { selection.contains($0.id) }.map(\.candidate.item.path)
        )
        let previouslyLocked = Set(
            rows.filter { !$0.isSelectable }.map(\.candidate.item.path)
        )

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

        guard preservingSelection else {
            // Pre-tick everything admissible except the pieces that carry user
            // data — a sandbox container is the app's documents, and losing
            // those by default is not a tradeoff to make on the user's behalf.
            selection = Set(
                planned
                    .filter { $0.isSelectable && !$0.candidate.kind.carriesUserData }
                    .map(\.id)
            )
            return
        }

        selection = Set(
            planned.filter { row in
                guard row.isSelectable else { return false }
                let path = row.candidate.item.path
                // What the user had ticked stays ticked. Re-deriving the
                // defaults here would quietly undo their edits on every
                // refresh.
                if previouslySelected.contains(path) { return true }
                // Rows that just became selectable — the app quit — get the
                // default treatment, because unlocking them is the entire
                // reason this re-plan happened.
                if previouslyLocked.contains(path) { return !row.candidate.kind.carriesUserData }
                return false
            }
            .map(\.id)
        )
    }

    func clearSelection() {
        selectedApp = nil
        rows = []
        selection = []
        summary = nil
        leftovers = []
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
        environment.refreshDiskSpace()

        var lines = [
            "已将 \(outcome.removed.count) 项（\(ByteFormat.string(outcome.quarantinedBytes))）移入隔离区，"
            + "\(AppSettings.currentRetentionDays()) 天后自动删除，届时才会释放空间。"
        ]
        if !outcome.skipped.isEmpty {
            lines.append("跳过 \(outcome.skipped.count) 项：" + outcome.skipped.prefix(3).map(\.reason).joined(separator: "；"))
        }
        summary = lines.joined(separator: "\n")

        // Re-plan so the sheet shows what is actually left rather than a stale
        // list of paths that no longer exist.
        if let app = selectedApp {
            loadApps()
            let previousSummary = summary
            await select(app)
            summary = previousSummary
            // Whatever the planner still finds is, by definition, what the
            // uninstall did not get. Rows locked by a deny reason count too —
            // they are exactly the ones the user would otherwise never learn
            // about.
            leftovers = rows
        }
    }

    var isVerifiedClean: Bool { summary != nil && leftovers.isEmpty }

    func dismissSummary() {
        summary = nil
        leftovers = []
    }
}
