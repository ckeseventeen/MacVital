import SwiftUI
import AppKit
import MacVitalKit

/// The inspector. This is where the three-way split is made visible: the rule
/// engine's verdict, the model's explanation, and the user's decision each get
/// their own labelled block, so it is always clear which one is speaking.
struct ItemDetailPane: View {
    let finding: Finding?

    var body: some View {
        Group {
            if let finding {
                content(for: finding)
            } else {
                placeholder
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private var placeholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "sidebar.right")
                .font(.title)
                .foregroundStyle(.quaternary)
            Text("选中一项查看详情")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func content(for finding: Finding) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(finding)
                Divider()
                ruleBlock(finding)
                if let assessment = finding.assessment {
                    Divider()
                    aiBlock(assessment)
                }
                Divider()
                factsBlock(finding)
                actions(finding)
            }
            .padding(18)
        }
    }

    // MARK: - Blocks

    private func header(_ finding: Finding) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(finding.item.displayName)
                .font(.title3.weight(.semibold))
                .textSelection(.enabled)
            Text(finding.item.abbreviatedPath)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(3)
            HStack(spacing: 8) {
                SizeBadge(bytes: finding.item.sizeBytes, emphasized: true)
                if finding.item.isDirectory {
                    Text("\(finding.item.fileCount) 个文件")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                RebuildableBadge(rebuildable: finding.item.rebuildable)
            }
        }
    }

    /// Deterministic layer. Always present, always the same for the same path.
    private func ruleBlock(_ finding: Finding) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("规则引擎", systemImage: "shield.lefthalf.filled")
            AdmissionBadge(decision: finding.decision)
            Text(finding.decision.rationale)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Text("规则 \(finding.decision.ruleID)")
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
    }

    /// Model layer. Explicitly labelled as advisory so nobody mistakes a
    /// confidence score for a permission.
    private func aiBlock(_ assessment: AIAssessment) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel("模型判断", systemImage: "sparkles")
                Spacer()
                Text(sourceLabel(assessment.source))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if let attribution = assessment.attribution {
                LabeledContent("归属") { Text(attribution).textSelection(.enabled) }
                    .font(.callout)
            }
            Text(assessment.whatItIs)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                Text("清理后会发生什么")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(assessment.consequence)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 6) {
                ProgressView(value: assessment.confidence)
                    .frame(width: 90)
                Text("置信度 \(Int(assessment.confidence * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text("模型只提供解释与排序，不参与是否允许删除的判定。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func factsBlock(_ finding: Finding) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("文件信息", systemImage: "info.circle")
            LabeledContent("类型", value: finding.item.kindHint)
            LabeledContent("修改时间", value: RelativeDateFormat.string(finding.item.lastModified))
            if let accessed = finding.item.lastAccessed {
                LabeledContent("最近访问", value: RelativeDateFormat.string(accessed))
            }
            if let project = finding.item.ownerHint?.projectPath {
                LabeledContent("所属项目", value: PathRedaction.abbreviate(project))
            }
        }
        .font(.callout)
    }

    private func actions(_ finding: Finding) -> some View {
        HStack {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([finding.item.url])
            } label: {
                Label("在访达中显示", systemImage: "folder")
            }
            .controlSize(.small)

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(finding.item.path, forType: .string)
            } label: {
                Label("拷贝路径", systemImage: "doc.on.doc")
            }
            .controlSize(.small)
        }
        .padding(.top, 4)
    }

    private func sourceLabel(_ source: AISource) -> String {
        switch source {
        case .heuristic: return "内置规则表"
        case .localModel: return "本地模型"
        case .cloud: return "云端模型"
        }
    }
}

struct SectionLabel: View {
    let title: String
    let systemImage: String

    init(_ title: String, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }
}
