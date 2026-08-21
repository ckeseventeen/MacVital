import SwiftUI
import AppKit
import MacVitalKit

/// The inspector. This is where the three-way split is made visible: the rule
/// engine's verdict, the model's explanation, and the user's decision each get
/// their own labelled block, so it is always clear which one is speaking.
struct ItemDetailPane: View {
    let finding: Finding?
    /// Called after something holding this item was closed, so the caller can
    /// re-run the engine and unlock the row.
    var onOccupierClosed: () async -> Void = {}

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

            // `.inUse` is the only verdict here the user can clear, and saying
            // so without offering to do it left them to find the program, quit
            // it, come back and rescan. The uninstall page has had this since
            // the process terminator was written; a build directory a compiler
            // is holding is the same problem.
            if let target = ProcessTerminator.target(for: finding.decision) {
                OccupierActions(target: target, onClosed: onOccupierClosed)
            }
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

/// Closing whatever is holding a finding open.
///
/// Two steps, never one. The graceful quit is the button; force quit only
/// appears once that has visibly failed, and it asks first — it is the one
/// action in this app that can destroy work the user has not saved, which is
/// the exact opposite of what quarantine exists to guarantee.
private struct OccupierActions: View {
    let target: ProcessTerminator.Target
    let onClosed: () async -> Void

    @State private var isWorking = false
    @State private var refused = false
    @State private var notPermitted = false
    @State private var confirmingForce = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    Task { await close(force: false) }
                } label: {
                    Label("退出「\(target.name)」", systemImage: "stop.circle")
                }
                .controlSize(.small)
                .disabled(isWorking)

                if refused {
                    Button(role: .destructive) {
                        confirmingForce = true
                    } label: {
                        Label("强制结束", systemImage: "xmark.octagon")
                    }
                    .controlSize(.small)
                    .disabled(isWorking)
                }

                if isWorking {
                    ProgressView().controlSize(.small)
                }
            }

            if notPermitted {
                Text("这个进程属于系统或其他用户，MacVital 不以 root 运行，无法结束它。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if refused {
                Text("它没有响应退出请求，可能正在等待你保存内容。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .confirmationDialog("强制结束「\(target.name)」？", isPresented: $confirmingForce, titleVisibility: .visible) {
            Button("强制结束", role: .destructive) {
                Task { await close(force: true) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("强制结束不给程序保存的机会，未保存的内容会直接丢失，正在写入的文件也可能损坏。"
                 + "只有在它已经没有响应、或你确定没有未保存内容时才这么做。")
        }
    }

    private func close(force: Bool) async {
        isWorking = true
        defer { isWorking = false }

        let outcome = force
            ? await ProcessTerminator.forceQuit(target)
            : await ProcessTerminator.quit(target)

        switch outcome {
        case .closed:
            refused = false
            notPermitted = false
            await onClosed()
        case .stillRunning:
            // Only a graceful refusal earns the harsher button. If force
            // already failed there is nothing further to escalate to.
            refused = !force
            notPermitted = false
        case .notPermitted:
            refused = false
            notPermitted = true
        }
    }
}
