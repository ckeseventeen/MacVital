import SwiftUI
import MacVitalKit

/// Size, rendered so the eye can sort a column without reading numbers.
struct SizeBadge: View {
    let bytes: Int64
    var emphasized: Bool = false

    var body: some View {
        Text(ByteFormat.string(bytes))
            .font(.system(.callout, design: .rounded).weight(emphasized ? .semibold : .regular))
            .monospacedDigit()
            .foregroundStyle(emphasized ? Color.primary : Color.secondary)
    }
}

/// The rule engine's verdict. Deliberately the most prominent chip on the row:
/// this is the thing that decides whether the checkbox works at all.
struct AdmissionBadge: View {
    let decision: RuleDecision

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(tint.opacity(0.14), in: Capsule())
            .foregroundStyle(tint)
    }

    private var title: String {
        switch decision.admission {
        case .allow: return "可清理"
        case .allowWithPrivilege: return "需授权"
        case .deny: return "已锁定"
        }
    }

    private var symbol: String {
        switch decision.admission {
        case .allow: return "checkmark.shield"
        case .allowWithPrivilege: return "key"
        case .deny: return "lock"
        }
    }

    private var tint: Color {
        switch decision.admission {
        case .allow: return .green
        case .allowWithPrivilege: return .orange
        case .deny: return .secondary
        }
    }
}

/// The model's confidence, shown as a value rather than a vibe. A number the
/// user can learn to distrust is better than a claim they cannot check.
struct ConfidenceBadge: View {
    let assessment: AIAssessment?

    var body: some View {
        if let assessment {
            HStack(spacing: 4) {
                Image(systemName: symbol(for: assessment.recommendation))
                    .font(.caption2)
                Text("\(Int(assessment.confidence * 100))%")
                    .font(.caption.monospacedDigit())
            }
            .foregroundStyle(tint(for: assessment))
            .help("\(sourceLabel(assessment.source))：\(assessment.whatItIs)")
        } else {
            EmptyView()
        }
    }

    private func symbol(for recommendation: AIRecommendation) -> String {
        switch recommendation {
        case .safeToRemove: return "sparkles"
        case .reviewFirst: return "eye"
        case .keep: return "hand.raised"
        }
    }

    private func tint(for assessment: AIAssessment) -> Color {
        guard assessment.confidence >= AIAssessment.autoSelectConfidenceFloor else { return .secondary }
        switch assessment.recommendation {
        case .safeToRemove: return .accentColor
        case .reviewFirst: return .orange
        case .keep: return .red
        }
    }

    private func sourceLabel(_ source: AISource) -> String {
        switch source {
        case .heuristic: return "内置规则"
        case .localModel: return "本地模型"
        case .cloud: return "云端模型"
        }
    }
}

struct RebuildableBadge: View {
    let rebuildable: Bool

    var body: some View {
        if rebuildable {
            Label("可重建", systemImage: "arrow.triangle.2.circlepath")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .labelStyle(.titleAndIcon)
        }
    }
}
