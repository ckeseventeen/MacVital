import SwiftUI
import MacVitalKit

/// The authorization step. It states plainly what will happen, what will not
/// happen (nothing is deleted yet), and which items need root — because the
/// user granting that is a separate decision from the user selecting files.
struct ConfirmSheet: View {
    @Binding var isPresented: Bool
    @EnvironmentObject private var model: ScanViewModel
    @EnvironmentObject private var environment: AppEnvironment

    private var selected: [Finding] {
        model.findings.filter { model.selection.contains($0.id) }
    }

    private var privileged: [Finding] {
        selected.filter { $0.decision.admission == .allowWithPrivilege }
    }

    private var needsHelper: Bool {
        !privileged.isEmpty && environment.helperStatus != .enabled
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("确认清理")
                    .font(.title2.weight(.semibold))
                Text("将 \(selected.count) 项（共 \(ByteFormat.string(model.selectedBytes))）移入隔离区。")
                    .foregroundStyle(.secondary)
            }

            GroupBox {
                HStack(spacing: 10) {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("这一步不会真正删除任何东西。")
                            .font(.callout.weight(.medium))
                        Text("文件会被移动到隔离区，\(environment.settings.retentionDays) 天后才清除。期间可以随时还原。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(4)
            }

            categoryBreakdown

            if !privileged.isEmpty {
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("其中 \(privileged.count) 项位于系统目录", systemImage: "key")
                            .font(.callout.weight(.medium))
                        Text("这些需要特权助手来移动。\(needsHelper ? "助手尚未安装，安装时系统会要求你授权一次。" : "助手已就绪。")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if needsHelper {
                            Button("安装特权助手") { environment.installHelper() }
                                .controlSize(.small)
                        }
                    }
                    .padding(4)
                }
            }

            Divider()

            HStack {
                Button("取消") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("移入隔离区") {
                    isPresented = false
                    Task { await model.performCleanup() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 480)
    }

    private var categoryBreakdown: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(breakdown, id: \.category) { entry in
                HStack {
                    CategoryIcon(category: entry.category, size: 22)
                    Text(entry.category.title)
                        .font(.callout)
                    Spacer()
                    Text("\(entry.count) 项")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text(ByteFormat.string(entry.bytes))
                        .font(.callout.monospacedDigit())
                        .frame(width: 84, alignment: .trailing)
                }
            }
        }
    }

    private var breakdown: [(category: ScanCategory, count: Int, bytes: Int64)] {
        Dictionary(grouping: selected) { $0.item.category }
            .map { (category: $0.key, count: $0.value.count, bytes: $0.value.reduce(Int64(0)) { $0 + $1.item.sizeBytes }) }
            .sorted { $0.bytes > $1.bytes }
    }
}
