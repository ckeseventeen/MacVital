import SwiftUI
import MacVitalKit

/// The scan flow: scan from the toolbar, review in a table, act from the bar at
/// the bottom.
///
/// The page used to carry its own title block, a summary card built around a
/// large ring, and the scan button inside the content. A Mac window already
/// has a place for each of those — the title and subtitle in the toolbar, the
/// commands on the toolbar, the summary next to the action it summarises — so
/// they moved there, and the table got the space back.
struct JunkCleanerPage: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(ScanViewModel.self) private var model

    @State private var searchText = ""
    @State private var sortOrder = [KeyPathComparator(\Finding.item.sizeBytes, order: .reverse)]
    @State private var rowSelection = Set<Finding.ID>()
    @State private var confirmingSelectAll = false
    /// Closed until asked for, as in Finder and Mail: open, it takes a third
    /// of a default-sized window to say "select something", and the table
    /// already carries what most rows need in its 说明 column and tooltips.
    @SceneStorage("junk.showInspector") private var showInspector = false

    var body: some View {
        content
            .permissionBannerInset()
            .navigationSubtitle(subtitle)
            .toolbar { toolbar }
            .searchable(text: $searchText, placement: .toolbar, prompt: "搜索名称、路径或归属")
            .inspector(isPresented: inspectorBinding) {
                inspector
                    .inspectorColumnWidth(min: 240, ideal: 280, max: 420)
            }
            .onChange(of: rowSelection) { _, ids in
                model.selectedFindingID = ids.count == 1 ? ids.first : nil
            }
            .confirmationDialog(
                "全选所有可清理项目？",
                isPresented: $confirmingSelectAll,
                titleVisibility: .visible
            ) {
                Button("全选 \(selectableCount) 项") { model.selectEverySelectable() }
                Button("取消", role: .cancel) {}
            } message: {
                Text("这会同时勾选 \(explicitCategoryNames)。请确认这些文件确实可以清理；被安全规则锁定的项目不会被选中。")
            }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if model.isScanning {
            scanningState
        } else if model.findings.isEmpty {
            if model.phase == .results {
                ContentUnavailableView {
                    Label("没有发现可清理的内容", systemImage: "checkmark.seal")
                } description: {
                    Text("这次扫描的范围里没有找到符合清理规则的项目。")
                } actions: {
                    Button("重新扫描") { Task { await model.startScan() } }
                }
            } else {
                ContentUnavailableView {
                    Label("还没有扫描过", systemImage: "sparkle.magnifyingglass")
                } description: {
                    Text("扫描只读取文件信息，不会改动任何东西。")
                } actions: {
                    Button("开始扫描") { Task { await model.startScan() } }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
            }
        } else {
            VStack(spacing: 0) {
                filterBar
                if !model.scanWarnings.isEmpty { warnings }
                Divider()
                if displayedFindings.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                } else {
                    FindingsTable(
                        findings: displayedFindings,
                        sortOrder: $sortOrder,
                        rowSelection: $rowSelection
                    )
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { actionBar }
        }
    }

    private var scanningState: some View {
        VStack(spacing: 14) {
            ProgressView(value: model.progressFraction) {
                Text("正在扫描")
                    .font(.headline)
            } currentValueLabel: {
                Text(model.progressText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: 360)
            Button("停止") { model.cancelScan() }
                .keyboardShortcut(.cancelAction)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var warnings: some View {
        Label {
            Text("部分扫描未完成，结果不完整：\n" + model.scanWarnings.joined(separator: "\n"))
                .textSelection(.enabled)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .font(.callout)
        .foregroundStyle(.orange)
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Filtering

    /// Category focus, then search, then the table's sort order — in that
    /// order, so sorting never has to look at rows that will not be shown.
    private var displayedFindings: [Finding] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let visible = query.isEmpty ? model.visibleFindings : model.visibleFindings.filter { finding in
            finding.item.displayName.localizedStandardContains(query)
                || finding.item.path.localizedStandardContains(query)
                || (finding.item.ownerHint?.label?.localizedStandardContains(query) ?? false)
                || (finding.assessment?.attribution?.localizedStandardContains(query) ?? false)
        }
        return visible.sorted(using: sortOrder)
    }

    /// One chip per category present in the results. `focusedCategory` drives
    /// both what the table shows and what 全选 means.
    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                FilterChip(title: "全部", count: model.findings.count, tint: Theme.accent,
                           isOn: model.focusedCategory == nil) {
                    model.focusedCategory = nil
                }
                ForEach(presentCategories) { category in
                    FilterChip(title: category.title, count: model.count(in: category),
                               tint: category.tint, isOn: model.focusedCategory == category) {
                        model.focusedCategory = model.focusedCategory == category ? nil : category
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private var presentCategories: [ScanCategory] {
        ScanCategory.allCases.filter { model.count(in: $0) > 0 }
    }

    // MARK: - Inspector

    /// The inspector only means something once there are results to inspect.
    private var inspectorBinding: Binding<Bool> {
        Binding(
            get: { showInspector && !model.findings.isEmpty },
            set: { showInspector = $0 }
        )
    }

    @ViewBuilder
    private var inspector: some View {
        if rowSelection.count > 1 {
            ContentUnavailableView {
                Label("已选择 \(rowSelection.count) 项", systemImage: "square.stack.3d.up")
            } description: {
                Text("共 \(ByteFormat.string(bytes(of: rowSelection)))。右键可以一起勾选或在访达中显示。")
            }
        } else {
            ItemDetailPane(finding: model.selectedFinding) {
                // Whatever was holding it is gone; re-derive the verdicts so
                // the row unlocks instead of staying stale until a full rescan.
                await model.revalidate()
            }
        }
    }

    private func bytes(of ids: Set<Finding.ID>) -> Int64 {
        model.findings.filter { ids.contains($0.id) }.reduce(0) { $0 + $1.item.sizeBytes }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            scanButton
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                showInspector.toggle()
            } label: {
                Label("检查器", systemImage: "sidebar.trailing")
            }
            .help("显示或隐藏检查器")
            .disabled(model.findings.isEmpty)
        }
    }

    /// A split button: the body scans, the arrow chooses what to scan. The
    /// scope used to be a separate menu next to the button; it is a setting
    /// *of* the scan, so it belongs on it — Mail's Get Mail and Xcode's Run do
    /// the same.
    @ViewBuilder
    private var scanButton: some View {
        if model.isScanning {
            Button {
                model.cancelScan()
            } label: {
                Label("停止扫描", systemImage: "stop.fill")
            }
            .help("停止扫描（⌘.）")
        } else {
            Menu {
                Section("扫描范围") {
                    ForEach(ScanCategory.sweepCategories) { category in
                        Toggle(category.title, isOn: scopeBinding(for: category))
                    }
                }
            } label: {
                Label(model.findings.isEmpty ? "扫描" : "重新扫描", systemImage: "arrow.clockwise")
            } primaryAction: {
                Task { await model.startScan() }
            }
            .disabled(model.isCleaning)
            .help("扫描（⌘R）。点箭头选择这次扫描哪些类别")
        }
    }

    private func scopeBinding(for category: ScanCategory) -> Binding<Bool> {
        Binding(
            get: { model.enabledCategories.contains(category) },
            set: { isOn in
                if isOn {
                    model.enabledCategories.insert(category)
                } else if model.enabledCategories.count > 1 {
                    // Never let the set empty out: a scan with no categories
                    // finds nothing and looks like a bug.
                    model.enabledCategories.remove(category)
                }
            }
        )
    }

    private var subtitle: String {
        if model.isScanning { return "正在扫描…" }
        guard !model.findings.isEmpty else {
            return model.phase == .results ? "没有发现可清理的内容" : "尚未扫描"
        }
        var parts = ["\(model.findings.count) 项", "\(ByteFormat.string(model.totalFoundBytes)) 可回收"]
        if model.deniedCount > 0 { parts.append("\(model.deniedCount) 项已锁定") }
        parts.append("用时 \(String(format: "%.1f", model.lastScanDuration)) 秒")
        return parts.joined(separator: " · ")
    }

    // MARK: - Action bar

    /// The summary sits next to the action it summarises, at the bottom edge,
    /// like Photos' import bar.
    private var actionBar: some View {
        HStack(spacing: 14) {
            if model.isCleaning {
                ProgressView(
                    value: Double(model.cleanupProgress.done),
                    total: Double(max(model.cleanupProgress.total, 1))
                )
                .frame(width: 140)
                Text("正在移入隔离区 \(model.cleanupProgress.done)/\(model.cleanupProgress.total)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text("已选 \(ByteFormat.string(model.selectedBytes))")
                        .font(.headline)
                        .monospacedDigit()
                    Text("\(model.selection.count) 项 · 移入隔离区后 \(environment.settings.retentionDays) 天释放空间")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            selectionMenu

            Button("移入隔离区…") {
                environment.showConfirm = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(model.selection.isEmpty || model.isCleaning)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var selectionMenu: some View {
        Menu("选择") {
            Button(model.focusedCategory == nil ? "全选" : "全选本类") {
                if model.focusedCategory == nil, !model.categoriesNeedingExplicitSelection.isEmpty {
                    confirmingSelectAll = true
                } else {
                    model.selectAll(in: model.focusedCategory)
                }
            }
            Button(model.focusedCategory == nil ? "全不选" : "全不选本类") {
                model.deselectAll(in: model.focusedCategory)
            }
            .disabled(model.selection.isEmpty)
            Divider()
            Button("恢复推荐选择") { model.resetToRecommended() }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(model.isCleaning)
        .help(selectAllHelp)
    }

    /// Says out loud what a global 全选 will not touch without asking.
    private var selectAllHelp: String {
        let skipped = model.categoriesNeedingExplicitSelection
        guard !skipped.isEmpty else { return "勾选当前范围内所有可清理的项目" }
        return "全选会先请你确认，因为包含 \(skipped.map(\.title).joined(separator: "、"))"
    }

    private var selectableCount: Int {
        model.findings.filter(\.isSelectable).count
    }

    private var explicitCategoryNames: String {
        model.categoriesNeedingExplicitSelection.map(\.title).joined(separator: "、")
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
            HStack(spacing: 4) {
                Text(title)
                    .fontWeight(isOn ? .medium : .regular)
                Text("\(count)")
                    .monospacedDigit()
                    .foregroundStyle(isOn ? tint : Color.secondary)
            }
            .font(.callout)
            .foregroundStyle(isOn ? tint : Color.primary)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(tint.opacity(isOn ? 0.15 : (isHovering ? 0.07 : 0))))
            .overlay(Capsule().strokeBorder(isOn ? tint.opacity(0.4) : Theme.separator, lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
