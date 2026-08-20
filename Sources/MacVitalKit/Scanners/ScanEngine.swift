import Foundation

public struct ScanResult: Sendable {
    public var findings: [Finding]
    public var defaultSelection: Set<UUID>
    public var duration: TimeInterval
    public var deniedCount: Int

    public init(findings: [Finding], defaultSelection: Set<UUID>, duration: TimeInterval, deniedCount: Int) {
        self.findings = findings
        self.defaultSelection = defaultSelection
        self.duration = duration
        self.deniedCount = deniedCount
    }
}

/// Combines the scanners' independent progress reports into one number.
///
/// Each scanner reports its own 0→1. Forwarding those straight through meant
/// the bar jumped between five unrelated timelines — and since each hop to the
/// main actor is its own `Task`, they did not even arrive in order, so it also
/// went backwards. Averaging the per-scanner maxima gives a single figure that
/// only moves forward.
private final class ProgressAggregator: @unchecked Sendable {
    private let lock = NSLock()
    private var fractions: [ScanCategory: Double]
    private let total: Double
    private let report: @Sendable (ScanProgress) -> Void

    init(categories: [ScanCategory], report: @escaping @Sendable (ScanProgress) -> Void) {
        self.fractions = Dictionary(uniqueKeysWithValues: categories.map { ($0, 0.0) })
        self.total = Double(max(categories.count, 1))
        self.report = report
    }

    func record(_ progress: ScanProgress) {
        lock.lock()
        if let fraction = progress.fraction, let category = progress.category {
            fractions[category] = max(fractions[category] ?? 0, min(max(fraction, 0), 1))
        }
        let combined = fractions.values.reduce(0, +) / total
        lock.unlock()
        // Scanning owns 0…0.9; the explanation pass owns the last tenth.
        report(ScanProgress(
            category: progress.category,
            message: progress.message,
            fraction: combined * 0.9
        ))
    }
}

/// Orchestration: run the scanners, run every item through the rule engine,
/// then hand the admissible ones to the AI layer for explanation.
///
/// The order matters. Items the engine denies are never sent to a model —
/// there is nothing to explain and no reason to describe a protected path to
/// anything, local or remote.
public struct ScanEngine: Sendable {
    private let scanners: [Scanner]
    private let rules: RuleIndex
    private let advisor: AIAdvisor
    private let quarantineRoot: String

    public init(
        rules: RuleIndex = RuleIndex(),
        advisor: AIAdvisor = CompositeAdvisor(primary: nil),
        quarantineRoot: String,
        scanners: [Scanner]? = nil
    ) {
        self.rules = rules
        self.advisor = advisor
        self.quarantineRoot = quarantineRoot
        // Declaration order is also precedence order: when two scanners produce
        // the same path, the earlier one wins (see `scan`). The duplicate
        // scanner sits ahead of the large-file scanner deliberately — both walk
        // the same roots, and "副本，保留 …" tells the user strictly more about a
        // big file than "大文件" does.
        self.scanners = scanners ?? [
            DeveloperResidueScanner(),
            AppResidueScanner(),
            CacheScanner(),
            EmptyDirectoryScanner(),
            DuplicateFileScanner(),
            LargeFileScanner(),
        ]
    }

    public func scan(
        categories: Set<ScanCategory> = Set(ScanCategory.sweepCategories),
        options: ScanOptions = .default,
        progress: @Sendable @escaping (ScanProgress) -> Void
    ) async throws -> ScanResult {
        let start = Date()
        let context = ScanContext(rules: rules, options: options)
        let active = scanners.filter { categories.contains($0.category) }
        let aggregator = ProgressAggregator(categories: active.map(\.category), report: progress)

        // Scanners are independent and mostly I/O bound; run them together.
        //
        // Results are keyed by the scanner's index so they can be put back in
        // declaration order afterwards. Concurrent completion order is
        // arbitrary, and without this the winner of a path collision below
        // would change from run to run.
        var produced: [Int: [ScanItem]] = [:]
        try await withThrowingTaskGroup(of: (Int, [ScanItem]).self) { group in
            for (index, scanner) in active.enumerated() {
                group.addTask {
                    do {
                        let items = try await scanner.scan(
                            context: context,
                            progress: { aggregator.record($0) }
                        )
                        return (index, items)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        Log.scan.error("\(scanner.category.rawValue, privacy: .public) scanner failed: \(error.localizedDescription, privacy: .public)")
                        return (index, [])
                    }
                }
            }
            for try await (index, items) in group {
                produced[index] = items
            }
        }

        // One finding per path.
        //
        // The large-file and duplicate scanners walk the same roots, so a big
        // file that also has a copy elsewhere came back from both. It was
        // counted twice in "发现 X 可回收", and if the user ticked both rows the
        // second one failed during cleanup with "文件已不存在，可能已被其他程序
        // 清理" — about a file they had just removed themselves.
        var items: [ScanItem] = []
        var claimed = Set<String>()
        for index in produced.keys.sorted() {
            for item in produced[index] ?? [] where claimed.insert(item.path).inserted {
                items.append(item)
            }
        }

        // One process snapshot for the whole evaluation pass, taken after the
        // scan so it reflects what is running now rather than 40 seconds ago.
        let engine = RuleEngine(
            rules: rules,
            processIndex: RunningProcessIndex.snapshot(),
            selfProtectedPrefixes: [quarantineRoot]
        )

        var findings: [Finding] = []
        var deniedCount = 0
        for item in items {
            let decision = engine.evaluate(item)
            if decision.isDenied { deniedCount += 1 }
            findings.append(Finding(item: item, decision: decision))
        }

        // Explanations, for admissible items only.
        progress(ScanProgress(category: nil, message: "生成说明", fraction: 0.95))
        let explainable = findings.filter(\.isSelectable)
        if !explainable.isEmpty {
            let evidence = explainable.map {
                EvidenceCollector.collect(for: $0.item, rule: rules.rule(for: $0.item.ruleID))
            }
            if let assessments = try? await advisor.assess(evidence) {
                for index in findings.indices {
                    findings[index].assessment = assessments[findings[index].id]
                }
            }
        }

        findings.sort { $0.rank > $1.rank }
        let selection = CleanPlanBuilder.defaultSelection(for: findings, rules: rules)

        return ScanResult(
            findings: findings,
            defaultSelection: selection,
            duration: Date().timeIntervalSince(start),
            deniedCount: deniedCount
        )
    }
}
