import SwiftUI
import MacVitalKit

/// The undo surface. Everything the app has removed is here until the
/// retention window closes, with the rule and the explanation that justified
/// each removal still attached — so "why is this gone?" is answerable a week
/// later, which is when the question actually gets asked.
struct QuarantineView: View {
    @Binding var isPresented: Bool
    @StateObject private var model: QuarantineViewModel
    @State private var confirmPurgeAll = false

    /// The environment is passed explicitly rather than read from
    /// `@EnvironmentObject`, because the view model has to be constructed with
    /// it at `init` time and environment objects are not available that early.
    init(isPresented: Binding<Bool>, environment: AppEnvironment) {
        _isPresented = isPresented
        _model = StateObject(wrappedValue: QuarantineViewModel(environment: environment))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !model.orphans.isEmpty {
                orphanBanner
                Divider()
            }
            if model.records.isEmpty {
                emptyState
            } else {
                list
            }
            Divider()
            footer
        }
        .frame(width: 720, height: 520)
        .task { await model.reload() }
        .alert(
            "操作失败",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("好") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .confirmationDialog(
            "立即永久删除隔离区中的全部内容？",
            isPresented: $confirmPurgeAll,
            titleVisibility: .visible
        ) {
            Button("永久删除", role: .destructive) {
                Task { await model.purgeAll() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("此操作不可撤销，共 \(model.records.count) 项、\(ByteFormat.string(model.totalBytes))。")
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("隔离区")
                    .font(.title3.weight(.semibold))
                Text("\(model.records.count) 项 · \(ByteFormat.string(model.totalBytes))，到期后自动清除")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("关闭") { isPresented = false }
                .keyboardShortcut(.cancelAction)
        }
        .padding(16)
    }

    /// Orphans are not records, so they cannot be listed among them — none has
    /// an original path to go back to. One banner and one button is the whole
    /// interaction.
    private var orphanBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "questionmark.folder")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("发现 \(model.orphans.count) 个无主容器（\(ByteFormat.string(model.orphanBytes))）")
                    .font(.callout.weight(.medium))
                Text(model.orphansWithContent > 0
                     ? "其中 \(model.orphansWithContent) 个装着文件。它们没有对应的记录，既不会出现在上面的列表里，也不会到期自动清除 —— 只能在这里删掉。"
                     : "都是空目录，早期版本搬运失败时留下的。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("在访达中显示") { model.revealOrphans() }
                .controlSize(.small)
            Button(model.isReaping ? "清理中…" : "清理") {
                Task { await model.discardOrphans() }
            }
            .disabled(model.isReaping)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.08))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.largeTitle)
                .foregroundStyle(.quaternary)
            Text("隔离区是空的")
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        List(model.records) { record in
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: record.category.symbolName)
                    .frame(width: 18)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 3) {
                    Text(record.displayName)
                        .font(.callout.weight(.medium))
                    Text(record.abbreviatedOriginalPath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                    Text(record.aiSummary ?? record.rationale)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 4) {
                    Text(ByteFormat.string(record.sizeBytes))
                        .font(.callout.monospacedDigit())
                    Text("\(record.daysRemaining) 天后清除")
                        .font(.caption2)
                        .foregroundStyle(record.daysRemaining <= 1 ? .orange : .secondary)
                }

                // A row that needs root on a build that can never reach root
                // gets an explanation and a way out, not two buttons that fail
                // identically every time they are pressed.
                if model.needsHelper(record) {
                    VStack(alignment: .trailing, spacing: 4) {
                        Label("需要管理员权限", systemImage: "key.slash")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Button("在访达中显示") { model.revealInFinder(record) }
                            .controlSize(.small)
                    }
                    .help("当前构建是自签名的，无法使用特权助手（见「设置 → 安全」）。请在访达中手动处理。")
                } else {
                    VStack(spacing: 4) {
                        Button("还原") { Task { await model.restore(record) } }
                            .controlSize(.small)
                            .disabled(model.busyID == record.id)
                        Button("立即删除") { Task { await model.purge(record) } }
                            .controlSize(.small)
                            .disabled(model.busyID == record.id)
                    }
                }
            }
            .padding(.vertical, 4)
            .contextMenu {
                Button("在访达中显示") { model.revealInFinder(record) }
            }
        }
        .listStyle(.inset)
    }

    private var footer: some View {
        HStack {
            Text("还原会把文件放回原位置；若原位置已有同名文件，操作会中止而不是覆盖。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("清空隔离区", role: .destructive) { confirmPurgeAll = true }
                .disabled(model.records.isEmpty)
        }
        .padding(12)
    }
}
