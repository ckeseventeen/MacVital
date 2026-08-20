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
                // The summary card is about results, so it only appears when
                // there are some. It used to render for anything that was not
                // idle-and-empty, which meant that during a scan — phase
                // `.scanning`, findings still empty — the page showed
                // "发现 0 B 可回收 · 0 个类别" above a spinning progress bar.
                if !model.findings.isEmpty {
                    summaryCard
                    categoryFilter
                } else if !model.isScanning {
                    emptyState
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
            HStack(spacing: 10) {
                scopeMenu
                Button(model.isScanning ? "扫描中…" : "重新扫描") {
                    Task { await model.startScan() }
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(model.isScanning || model.isCleaning)
            }
        }
    }

    /// `enabledCategories` has been on the view model since the beginning and
    /// nothing ever wrote to it — so every scan swept everything, including the
    /// duplicate-file pass, which is by far the slowest. This is the control
    /// that was missing.
    private var scopeMenu: some View {
        Menu {
            ForEach(ScanCategory.sweepCategories) { category in
                Toggle(category.title, isOn: Binding(
                    get: { model.enabledCategories.contains(category) },
                    set: { isOn in
                        if isOn {
                            model.enabledCategories.insert(category)
                        } else if model.enabledCategories.count > 1 {
                            // Never let the set empty out: a scan with no
                            // categories finds nothing and looks like a bug.
                            model.enabledCategories.remove(category)
                        }
                    }
                ))
            }
        } label: {
            Label(scopeLabel, systemImage: "line.3.horizontal.decrease.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(model.isScanning || model.isCleaning)
        .help("选择这次扫描要走哪些类别")
    }

    private var scopeLabel: String {
        let enabled = model.enabledCategories.count
        let total = ScanCategory.sweepCategories.count
        return enabled == total ? "全部类别" : "\(enabled)/\(total) 类别"
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
                // The number inside the ring now matches what the ring is
                // filled to. It used to show the *total* while the arc showed
                // selected-over-total, which read as "this number is that far
                // along" — two different quantities in one glyph.
                VStack(spacing: 0) {
                    Text(ByteFormat.compact(model.selectedBytes))
                        .font(.system(size: 16, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(Theme.junk)
                    Text("已选")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.tertiaryLabel)
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

            // The byte count moved into the ring, so this column carries the
            // item count instead of repeating it.
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(model.selection.count) / \(model.findings.filter(\.isSelectable).count)")
                    .font(.system(size: 16, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.label)
                Text("项已勾选")
                    .font(.system(size: 12))
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

    /// Counted over selectable findings only, to match `totalFoundBytes` on the
    /// same card. Counting every finding meant "N 个类别" and "X 可回收" were
    /// describing two different sets of rows.
    private var categoryCount: Int {
        Set(model.findings.filter(\.isSelectable).map(\.item.category)).count
    }

    // MARK: - Category filter

    /// `focusedCategory` was never assigned anywhere, so `visibleFindings`
    /// always returned everything and the footer's "全选" was always global.
    /// These chips are what was supposed to drive it.
    private var categoryFilter: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FilterChip(
                    title: "全部",
                    count: model.findings.count,
                    tint: Theme.accent,
                    isOn: model.focusedCategory == nil
                ) { model.focusedCategory = nil }

                ForEach(presentCategories) { category in
                    FilterChip(
                        title: category.title,
                        count: model.count(in: category),
                        tint: category.tint,
                        isOn: model.focusedCategory == category
                    ) {
                        model.focusedCategory = model.focusedCategory == category ? nil : category
                    }
                }
            }
            .padding(.vertical, 1)
        }
    }

    private var presentCategories: [ScanCategory] {
        ScanCategory.allCases.filter { model.count(in: $0) > 0 }
    }

    /// Says out loud what a global 全选 will not touch. Without this the button
    /// just appears not to work on those rows.
    private var selectAllHelp: String {
        let skipped = model.categoriesNeedingExplicitSelection
        guard !skipped.isEmpty else { return "勾选当前范围内所有可清理的项目" }
        return "勾选所有可清理的项目，但不含 \(skipped.map(\.title).joined(separator: "、"))"
            + " —— 这几类需要你逐项确认。先在上方选中该分类，再用「全选本类」。"
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
                Text("已选 ")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryLabel)
                + Text(ByteFormat.string(model.selectedBytes))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.label)
                + Text("，移入隔离区后 \(environment.settings.retentionDays) 天释放")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryLabel)
            }

            Spacer()

            Button(model.focusedCategory == nil ? "全选" : "全选本类") {
                model.selectAll(in: model.focusedCategory)
            }
            .buttonStyle(.link)
            .font(.system(size: 13))
            .help(selectAllHelp)
            // The other two list pages have had this since the start; only the
            // main cleaner was missing it.
            Button(model.focusedCategory == nil ? "全不选" : "全不选本类") {
                model.deselectAll(in: model.focusedCategory)
            }
            .buttonStyle(.link)
            .font(.system(size: 13))
            .disabled(model.selection.isEmpty)
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

// MARK: - Filter chip

private struct FilterChip: View {
    let title: String
    let count: Int
    let tint: Color
    let isOn: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 12, weight: isOn ? .medium : .regular))
                Text("\(count)")
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .opacity(0.75)
            }
            .foregroundStyle(isOn ? tint : Theme.secondaryLabel)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(tint.opacity(isOn ? 0.16 : (isHovering ? 0.08 : 0))))
            .overlay(Capsule().strokeBorder(isOn ? tint.opacity(0.45) : Theme.separator, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
