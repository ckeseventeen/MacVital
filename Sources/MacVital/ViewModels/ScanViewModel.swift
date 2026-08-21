import Foundation
import MacVitalKit
import SwiftUI

@MainActor
final class ScanViewModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case scanning
        case results
        case cleaning
        case done(CleanupSummary)
    }

    struct CleanupSummary: Equatable {
        /// Moved into quarantine. Free space does not change until it expires.
        var quarantinedBytes: Int64
        var removedCount: Int
        var skipped: [String]
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var findings: [Finding] = []
    @Published var selection: Set<UUID> = []
    @Published var enabledCategories: Set<ScanCategory> = Set(ScanCategory.sweepCategories)
    @Published var focusedCategory: ScanCategory?
    @Published var selectedFindingID: UUID?
    @Published private(set) var progressText: String = ""
    @Published private(set) var progressFraction: Double = 0
    @Published private(set) var lastScanDuration: TimeInterval = 0
    @Published private(set) var deniedCount: Int = 0
    @Published var errorMessage: String?
    @Published private(set) var cleanupProgress: (done: Int, total: Int) = (0, 0)

    private let environment: AppEnvironment
    private var scanTask: Task<Void, Never>?
    /// Incremented on every `startScan`. A scan that was superseded while it
    /// was still winding down must not write its result — or its cancellation —
    /// over the state of the scan that replaced it.
    private var scanGeneration = 0

    init(environment: AppEnvironment) {
        self.environment = environment
    }

    var isScanning: Bool { phase == .scanning }
    var isCleaning: Bool { phase == .cleaning }

    var visibleFindings: [Finding] {
        guard let focusedCategory else { return findings }
        return findings.filter { $0.item.category == focusedCategory }
    }

    var selectedFinding: Finding? {
        findings.first { $0.id == selectedFindingID }
    }

    var selectedBytes: Int64 {
        findings.filter { selection.contains($0.id) }.reduce(0) { $0 + $1.item.sizeBytes }
    }

    var totalFoundBytes: Int64 {
        findings.filter(\.isSelectable).reduce(0) { $0 + $1.item.sizeBytes }
    }

    func bytes(in category: ScanCategory) -> Int64 {
        findings.filter { $0.item.category == category && $0.isSelectable }
            .reduce(0) { $0 + $1.item.sizeBytes }
    }

    func count(in category: ScanCategory) -> Int {
        findings.filter { $0.item.category == category }.count
    }

    // MARK: - Scan

    func startScan() async {
        scanTask?.cancel()
        scanGeneration += 1
        let generation = scanGeneration
        phase = .scanning
        findings = []
        selection = []
        errorMessage = nil
        progressFraction = 0
        progressText = "准备扫描"

        let engine = environment.makeScanEngine()
        let options = environment.settings.scanOptions()
        let categories = enabledCategories

        // Built here rather than inline in the task below: nesting a second
        // `[weak self]` inside one is a capture of the outer binding, not of
        // `self`, which Swift 6 rejects outright.
        let onProgress: @Sendable (ScanProgress) -> Void = { [weak self] progress in
            Task { @MainActor in
                guard let self, self.scanGeneration == generation else { return }
                self.progressText = [progress.category?.title, progress.message]
                    .compactMap { $0 }
                    .joined(separator: " · ")
                if let fraction = progress.fraction {
                    // Each report reaches the main actor in its own `Task`, so
                    // they can land out of order even though the engine only
                    // ever emits a rising number. Clamping upward keeps the bar
                    // from stuttering backwards; `startScan` resets it to 0.
                    self.progressFraction = max(self.progressFraction, fraction)
                }
            }
        }

        let task = Task { [weak self] in
            do {
                let result = try await engine.scan(
                    categories: categories,
                    options: options,
                    progress: onProgress
                )
                await MainActor.run { [weak self] in
                    guard let self, self.scanGeneration == generation else { return }
                    self.findings = result.findings
                    self.selection = result.defaultSelection
                    self.lastScanDuration = result.duration
                    self.deniedCount = result.deniedCount
                    self.progressFraction = 1
                    self.phase = .results
                }
            } catch is CancellationError {
                await MainActor.run { [weak self] in
                    guard let self, self.scanGeneration == generation else { return }
                    self.phase = .idle
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.scanGeneration == generation else { return }
                    self.errorMessage = error.localizedDescription
                    self.phase = .idle
                }
            }
        }
        scanTask = task
        await task.value
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        scanGeneration += 1
        phase = .idle
    }

    /// Re-run the engine over the findings already on screen.
    ///
    /// The process snapshot is taken once, when the scan runs, so a row locked
    /// with `.inUse` stays locked for the life of that scan — the user quits
    /// the app that was holding it and nothing on screen changes, which reads
    /// as the lock being permanent when for this one reason it is not.
    ///
    /// Cheap on purpose: it re-evaluates existing items rather than re-walking
    /// the disk. Same reason `UninstallViewModel.replan` exists.
    func revalidate() async {
        guard !findings.isEmpty else { return }
        let rules = environment.rules
        let quarantineRoot = environment.quarantineRoot
        let snapshot = findings

        let updated: [Finding] = await Task.detached(priority: .userInitiated) {
            let engine = RuleEngine(
                rules: rules,
                processIndex: RunningProcessIndex.snapshot(),
                selfProtectedPrefixes: [quarantineRoot]
            )
            return snapshot.map { finding in
                var revised = finding
                revised.decision = engine.evaluate(finding.item)
                return revised
            }
        }.value

        findings = updated
        deniedCount = updated.filter { $0.decision.isDenied }.count
        // A row that just became inadmissible must not stay ticked. The
        // coordinator would skip it anyway, but the footer's "将移动 N 项"
        // would have been counting it.
        let selectable = Set(updated.filter(\.isSelectable).map(\.id))
        selection.formIntersection(selectable)
    }

    // MARK: - Selection

    func toggle(_ finding: Finding) {
        guard finding.isSelectable else { return }
        if selection.contains(finding.id) {
            selection.remove(finding.id)
        } else {
            selection.insert(finding.id)
        }
    }

    /// Delegates to `CleanPlanBuilder` so this and `defaultSelection` cannot
    /// drift apart on what `requiresExplicitSelection` means — they already had
    /// once, and a global 全选 was quietly ticking every large file and
    /// duplicate the design says must be approved one at a time.
    func selectAll(in category: ScanCategory?) {
        selection.formUnion(CleanPlanBuilder.selectAll(in: category, findings: findings))
    }

    /// Categories the current scope's "select all" deliberately leaves alone,
    /// so the UI can say so rather than looking broken.
    var categoriesNeedingExplicitSelection: [ScanCategory] {
        guard focusedCategory == nil else { return [] }
        return Array(Set(findings.filter { $0.isSelectable && $0.item.category.requiresExplicitSelection }
            .map(\.item.category))).sorted { $0.title < $1.title }
    }

    func deselectAll(in category: ScanCategory?) {
        for finding in findings {
            guard category == nil || finding.item.category == category else { continue }
            selection.remove(finding.id)
        }
    }

    /// Reset to what the rules and the model agree on, discarding manual edits.
    func resetToRecommended() {
        selection = CleanPlanBuilder.defaultSelection(for: findings, rules: environment.rules)
    }

    // MARK: - Clean

    func performCleanup() async {
        guard !selection.isEmpty else { return }
        phase = .cleaning
        cleanupProgress = (0, selection.count)

        let coordinator = environment.coordinator
        let snapshot = findings
        let selected = selection

        let outcome = await coordinator.execute(
            findings: snapshot,
            selection: selected,
            progress: { done, total, name in
                Task { @MainActor [weak self] in
                    self?.cleanupProgress = (done, total)
                    self?.progressText = name
                }
            }
        )

        let removedPaths = Set(outcome.removed.map(\.originalPath))
        findings.removeAll { removedPaths.contains($0.item.path) }
        selection = []

        await environment.refreshQuarantine()
        // The quarantine total just changed and the dashboard shows it. Free
        // space has not moved — quarantine is on the same volume — but the tile
        // beside it has, and leaving both stale until the next window reopen
        // made the whole overview look frozen.
        environment.refreshDiskSpace()

        phase = .done(CleanupSummary(
            quarantinedBytes: outcome.quarantinedBytes,
            removedCount: outcome.removed.count,
            skipped: outcome.skipped.map { "\($0.item.displayName)：\($0.reason)" }
        ))
    }

    func dismissSummary() {
        phase = findings.isEmpty ? .idle : .results
    }
}
