import SwiftUI
import MacVitalKit

/// The scan flow, restyled to the spec: header + summary card with a ring,
/// then the findings list, then a footer with the primary action.
///
/// The findings list itself is unchanged — it is the same `Finding` rows with
/// the same rule-engine verdicts. Only the frame around it moved.
struct JunkCleanerPage: View {
    @EnvironmentObject private var environment: AppEnvironment
    @EnvironmentObject private var model: ScanViewModel

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 22) {
                header
                if model.phase == .idle && model.findings.isEmpty {
                    emptyState
                } else {
                    summaryCard
                }
            }
            .padding(.horizontal, Theme.Metric.pagePaddingH)
            .padding(.top, Theme.Metric.pagePaddingV)
            .padding(.bottom, 20)

            if !model.findings.isEmpty {
                Divider().overlay(Theme.separator)
                FindingsList()
                Divider().overlay(Theme.separator)
                footer
            } else if model.isScanning {
                Spacer()
                scanningState
                Spacer()
            } else {
                Spacer()
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        PageHeader(title: "垃圾清理", subtitle: subtitle) {
            Button(model.isScanning ? "扫描中…" : "重新扫描") {
                Task { await model.startScan() }
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .disabled(model.isScanning || model.isCleaning)
        }
    }

    private var subtitle: String {
        if model.isScanning { return "正在扫描…" }
        if model.findings.isEmpty { return "尚未扫描" }
        return "扫描完成 · 用时 \(String(format: "%.1f", model.lastScanDuration)) 秒 · \(model.findings.count) 项"
    }

    // MARK: - States

    private var emptyState: some View {
        Card(padding: 22) {
            HStack(spacing: 16) {
                GlyphTile(systemImage: "sparkle.magnifyingglass", tint: Theme.accent, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text("还没有扫描过")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Theme.label)
                    Text("扫描只读取文件信息，不会改动任何东西。")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.secondaryLabel)
                }
                Spacer(minLength: 0)
                Button("开始扫描") { Task { await model.startScan() } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
    }

    private var scanningState: some View {
        VStack(spacing: 12) {
            ProgressView(value: model.progressFraction)
                .progressViewStyle(.linear)
                .frame(maxWidth: 320)
            Text(model.progressText)
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondaryLabel)
            Button("取消") { model.cancelScan() }
                .buttonStyle(.link)
        }
    }

    private var summaryCard: some View {
        HStack(spacing: 22) {
            ProgressRing(
                value: selectedFraction,
                lineWidth: 7,
                tint: Theme.junk
            ) {
                VStack(spacing: 0) {
                    Text(ByteFormat.compact(model.totalFoundBytes))
                        .font(.system(size: 16, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(Theme.junk)
                }
            }
            .frame(width: 88, height: 88)

            VStack(alignment: .leading, spacing: 3) {
                Text("发现 \(ByteFormat.string(model.totalFoundBytes)) 可回收")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Theme.label)
                Text("\(categoryCount) 个类别 · 勾选要清理的项目")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryLabel)
                if model.deniedCount > 0 {
                    Label("\(model.deniedCount) 项被安全规则锁定", systemImage: "lock.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.tertiaryLabel)
                }
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 2) {
                Text("已选 \(ByteFormat.string(model.selectedBytes))")
                    .font(.system(size: 13, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.label)
                Text("\(model.selection.count) / \(model.findings.filter(\.isSelectable).count) 项")
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(Theme.secondaryLabel)
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .glassPanel()
    }

    private var selectedFraction: Double {
        let total = model.totalFoundBytes
        guard total > 0 else { return 0 }
        return Double(model.selectedBytes) / Double(total)
    }

    private var categoryCount: Int {
        Set(model.findings.map(\.item.category)).count
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if model.isCleaning {
                ProgressView().controlSize(.small)
                Text("正在移入隔离区 \(model.cleanupProgress.done)/\(model.cleanupProgress.total)")
                    .font(.system(size: 13))
                    .monospacedDigit()
                    .foregroundStyle(Theme.secondaryLabel)
            } else {
                Text("可回收 ")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryLabel)
                + Text(ByteFormat.string(model.selectedBytes))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.label)
            }

            Spacer()

            Button("全选") { model.selectAll(in: model.focusedCategory) }
                .buttonStyle(.link)
                .font(.system(size: 13))
            Button("恢复推荐") { model.resetToRecommended() }
                .buttonStyle(.link)
                .font(.system(size: 13))
                .help("回到规则引擎与模型共同建议的选择")

            Button {
                environment.showConfirm = true
            } label: {
                Text("移入隔离区")
                    .font(.system(size: 14, weight: .medium))
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.selection.isEmpty || model.isCleaning)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, Theme.Metric.pagePaddingH)
        .padding(.vertical, Theme.Metric.barPaddingV)
        .glassChrome()
    }
}
