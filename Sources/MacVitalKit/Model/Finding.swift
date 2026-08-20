import Foundation

/// A scan item joined with the engine's verdict and (optionally) the model's
/// assessment. This is what the UI renders.
public struct Finding: Identifiable, Hashable, Sendable {
    public var item: ScanItem
    public var decision: RuleDecision
    public var assessment: AIAssessment?

    public init(item: ScanItem, decision: RuleDecision, assessment: AIAssessment? = nil) {
        self.item = item
        self.decision = decision
        self.assessment = assessment
    }

    public var id: UUID { item.id }

    /// Whether the user is even allowed to tick the checkbox.
    public var isSelectable: Bool { !decision.isDenied }

    /// Sort key: biggest confident wins first, denied items last.
    public var rank: Double {
        guard isSelectable else { return -Double.greatestFiniteMagnitude }
        let sizeWeight = log2(Double(max(item.sizeBytes, 1)))
        let confidence = assessment?.confidence ?? 0.5
        let recommendationWeight: Double
        switch assessment?.recommendation ?? .reviewFirst {
        case .safeToRemove: recommendationWeight = 1.0
        case .reviewFirst: recommendationWeight = 0.6
        case .keep: recommendationWeight = 0.15
        }
        return sizeWeight * confidence * recommendationWeight
    }
}

/// The set of findings for one scan run, plus what the user has selected.
public struct CleanPlan: Sendable {
    public var findings: [Finding]
    public var selection: Set<UUID>

    public init(findings: [Finding], selection: Set<UUID>) {
        self.findings = findings
        self.selection = selection
    }

    public var reclaimableBytes: Int64 {
        findings.filter { selection.contains($0.id) }.reduce(0) { $0 + $1.item.sizeBytes }
    }

    public var totalFoundBytes: Int64 {
        findings.filter(\.isSelectable).reduce(0) { $0 + $1.item.sizeBytes }
    }

    public func findings(in category: ScanCategory) -> [Finding] {
        findings.filter { $0.item.category == category }
    }
}

public enum CleanPlanBuilder {
    /// The three-way intersection, applied at selection time.
    ///
    /// A box is ticked by default only when all of these hold:
    ///   1. the rule engine admits it,
    ///   2. the rule is marked auto-selectable (rebuildable, low blast radius),
    ///   3. the AI says `safeToRemove` with confidence above the floor —
    ///      or there is no AI assessment at all and the rule stands alone.
    ///
    /// The user supplies the third input by leaving the box ticked.
    public static func defaultSelection(for findings: [Finding], rules: RuleIndex) -> Set<UUID> {
        var selected = Set<UUID>()
        for finding in findings {
            guard finding.isSelectable else { continue }
            guard let rule = rules.rule(for: finding.item.ruleID), rule.autoSelectable else { continue }
            guard !finding.item.category.requiresExplicitSelection else { continue }

            if let assessment = finding.assessment {
                guard assessment.recommendation == .safeToRemove,
                      assessment.confidence >= AIAssessment.autoSelectConfidenceFloor
                else { continue }
            }
            selected.insert(finding.id)
        }
        return selected
    }

    /// What a "select all" button may tick.
    ///
    /// Lives here, next to `defaultSelection`, because the two have to agree
    /// about `requiresExplicitSelection` and for a long time they did not: the
    /// default selection dutifully skipped those categories while the footer's
    /// 全选 swept them in, so one click undid a guarantee the enum states in as
    /// many words — "every item must be individually approved by the user, no
    /// matter what the rule engine and the model say". A user's photo copies
    /// and 4 GB videos went into the selection wholesale.
    ///
    /// Scoping to a single category *is* the individual approval: choosing
    /// 大文件 and then 全选本类 is a deliberate act about a list you are
    /// looking at. A global select-all is not.
    public static func selectAll(
        in category: ScanCategory?,
        findings: [Finding]
    ) -> Set<UUID> {
        var selected = Set<UUID>()
        for finding in findings where finding.isSelectable {
            if let category {
                guard finding.item.category == category else { continue }
            } else {
                guard !finding.item.category.requiresExplicitSelection else { continue }
            }
            selected.insert(finding.id)
        }
        return selected
    }
}
