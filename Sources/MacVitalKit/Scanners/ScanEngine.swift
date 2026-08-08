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
        self.scanners = scanners ?? [
            DeveloperResidueScanner(),
            AppResidueScanner(),
            CacheScanner(),
            LargeFileScanner(),
            DuplicateFileScanner(),
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

        // Scanners are independent and mostly I/O bound; run them together.
        var items: [ScanItem] = []
        try await withThrowingTaskGroup(of: [ScanItem].self) { group in
            for scanner in active {
                group.addTask {
                    do {
                        return try await scanner.scan(context: context, progress: progress)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        Log.scan.error("\(scanner.category.rawValue, privacy: .public) scanner failed: \(error.localizedDescription, privacy: .public)")
                        return []
                    }
                }
            }
            for try await produced in group {
                items.append(contentsOf: produced)
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
        progress(ScanProgress(category: .developerResidue, message: "生成说明", fraction: 0.95))
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
