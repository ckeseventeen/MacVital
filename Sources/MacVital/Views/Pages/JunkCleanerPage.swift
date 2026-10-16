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
    @State private var showingSkipped = false
    @Environment(\.undoManager) private var undoManager
    /// Closed until asked for, as in Finder and Mail: open, it takes a third
    /// of a default-sized window to say "select something", and the table
    /// already carries what most rows need in its 说明 column and tooltips.
    @SceneStorage("junk.showInspector") private var showInspector = false

    var body: some View {
        content
            .permissionBannerInset()
            .navigationSubtitle(subtitle)
            .toolbar { toolbar }
            .searchable(text: $searchText, placement: .toolbar, prompt: "搜索名称、类别或路径")
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
            if let summary = model.lastSummary {
                // Everything on the list went. The result and the way back
                // stay on screen instead of an empty "nothing found".
                ContentUnavailableView {
                    Label("已移入隔离区 \(ByteFormat.string(summary.quarantinedBytes))", systemImage: "checkmark.circle")
                } description: {
                    Text("\(summary.removedCount) 项，\(environment.settings.retentionDays) 天后自动删除，届时才真正释放空间。")
                } actions: {
                    undoButton
                    Button("重新扫描") { Task { await model.startScan() } }
                }
            } else if model.phase == .results {
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
                if !model.scanWarnings.isEmpty {
                    warnings
                    Divider()
                }
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
        .padding(.vertical, 10)
        .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Filtering

    /// Search, then the table's sort order — so sorting never has to look at
    /// rows that will not be shown. The category name is searchable, which
    /// is what the row of category chips above the table used to be for; the
    /// 类别 column sorts by it as well.
    private var displayedFindings: [Finding] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        let visible = query.isEmpty ? model.findings : model.findings.filter { finding in
            finding.item.displayName.localizedStandardContains(query)
                || finding.item.path.localizedStandardContains(query)
                || finding.item.category.title.localizedStandardContains(query)
                || (finding.item.ownerHint?.label?.localizedStandardContains(query) ?? false)
                || (finding.assessment?.attribution?.localizedStandardContains(query) ?? false)
        }
        return visible.sorted(using: sortOrder)
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
    /// like Photos' import bar — and after a cleanup, the result and its undo
    /// take the same place until something is ticked again.
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
            } else if model.selection.isEmpty, let summary = model.lastSummary {
                cleanupResult(summary)
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text("已选 \(ByteFormat.string(model.selectedBytes))")
                        .font(.headline)
                        .monospacedDigit()
                    Text(selectionCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            selectionMenu

            Button("移入隔离区") {
                Task { await model.performCleanup() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            // Deliberately no keyboard shortcut. With the confirmation step
            // gone, a shortcut would be the whole gate between a keystroke and
            // moving files: during testing eight folders went into the
            // quarantine from an input nobody meant for this button, most
            // likely a ⌘⏎ — the "send" key in chat windows — arriving while
            // this window had focus. ⌘⌫ is no better: it is also "delete to
            // line start" in the search field. Undo stays on ⌘Z.
            .disabled(model.selection.isEmpty || model.isCleaning || model.isUndoing)
            .help("\(environment.settings.retentionDays) 天内可随时还原，⌘Z 撤销")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func cleanupResult(_ summary: ScanViewModel.CleanupSummary) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Label("已移入隔离区 \(ByteFormat.string(summary.quarantinedBytes))", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .monospacedDigit()
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(Theme.success)
                Text("\(summary.removedCount) 项 · \(environment.settings.retentionDays) 天后自动删除，届时才释放空间")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            undoButton
            if !summary.skipped.isEmpty {
                Button("\(summary.skipped.count) 项被跳过") { showingSkipped = true }
                    .buttonStyle(.link)
                    .popover(isPresented: $showingSkipped, arrowEdge: .top) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(summary.skipped, id: \.self) { line in
                                    Text(line)
                                        .font(.callout)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                            .padding(14)
                        }
                        .frame(width: 380)
                        .frame(maxHeight: 320)
                    }
            }
        }
    }

    private var undoButton: some View {
        Button(model.isUndoing ? "正在还原…" : "撤销") {
            // Taken here rather than through ⌘Z, so the menu item registered
            // for it would undo nothing.
            undoManager?.removeAllActions(withTarget: model)
            Task { await model.undoLastCleanup() }
        }
        .disabled(model.lastCleanup == nil || model.isUndoing)
        .help("把刚才移入隔离区的文件放回原处（⌘Z）")
    }

    /// What pressing the button will do, including the part it cannot.
    ///
    /// This used to be said by a confirmation sheet; the one thing from it
    /// still worth saying before the click is that rows needing the
    /// privileged helper will be skipped while it is not installed.
    private var selectionCaption: String {
        let privileged = model.findings.filter {
            model.selection.contains($0.id) && $0.decision.admission == .allowWithPrivilege
        }.count
        if privileged > 0, environment.helperStatus != .enabled {
            return "\(model.selection.count) 项 · 其中 \(privileged) 项需要特权助手，当前会跳过"
        }
        return "\(model.selection.count) 项 · 移入隔离区后 \(environment.settings.retentionDays) 天释放空间"
    }

    private var selectionMenu: some View {
        Menu("选择") {
            Button("全选") {
                if model.categoriesNeedingExplicitSelection.isEmpty {
                    model.selectAll()
                } else {
                    confirmingSelectAll = true
                }
            }
            Button("全不选") { model.deselectAll() }
                .disabled(model.selection.isEmpty)
            Divider()
            Button("恢复推荐选择") { model.resetToRecommended() }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(model.isCleaning || model.findings.isEmpty)
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
