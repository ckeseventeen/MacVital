import SwiftUI
import AppKit
import QuickLook
import MacVitalKit

/// Scan results as a sortable table, the way Finder and Disk Utility show
/// files.
///
/// This was a `List` grouped by category with fixed ordering. A table gives
/// the user the questions they actually ask of a list of files — what is
/// biggest, what is oldest, what is all of one kind — as a click on a column
/// header, plus column resizing, multi-row selection and a context menu, none
/// of which the list had.
///
/// Two selections, deliberately kept apart:
///
/// * **The checkbox** is what will be moved to quarantine. It is persistent,
///   it shows the rule engine and the model's recommended defaults, and it is
///   the user's explicit authorisation — the third input of the safety model.
/// * **Row selection** is ordinary table selection. It drives the inspector
///   and the context menu, and clicking elsewhere clears it, which is exactly
///   why it must not double as "delete these".
struct FindingsTable: View {
    @Environment(ScanViewModel.self) private var model

    let findings: [Finding]
    @Binding var sortOrder: [KeyPathComparator<Finding>]
    @Binding var rowSelection: Set<Finding.ID>

    /// Which columns are shown, their order and widths — changed from the
    /// header's context menu and by dragging, as in Finder, and kept per
    /// window.
    @SceneStorage("junk.columns")
    private var columnCustomization = TableColumnCustomization<Finding>()

    /// The file Quick Look is showing, if it is open.
    @State private var quickLookURL: URL?
    @State private var spaceMonitor = MonitorToken()

    var body: some View {
        Table(
            findings,
            selection: $rowSelection,
            sortOrder: $sortOrder,
            columnCustomization: $columnCustomization
        ) {
            TableColumn("") { finding in
                Toggle("", isOn: checkBinding(for: finding))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .disabled(!finding.isSelectable)
                    .help(finding.isSelectable ? "勾选以移入隔离区" : finding.decision.rationale)
                    .accessibilityLabel("清理 \(finding.item.displayName)")
            }
            .width(20)
            .customizationID("check")
            .disabledCustomizationBehavior(.all)

            TableColumn("名称", value: \.item.displayName) { finding in
                NameCell(finding: finding)
            }
            .width(min: 120, ideal: 240)
            .customizationID("name")
            .disabledCustomizationBehavior(.visibility)

            TableColumn("大小", value: \.item.sizeBytes) { finding in
                Text(ByteFormat.string(finding.item.sizeBytes))
                    .monospacedDigit()
                    .foregroundStyle(model.selection.contains(finding.id) ? Theme.junk : .primary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 60, ideal: 76, max: 110)
            .customizationID("size")

            TableColumn("类别", value: \.categorySortKey) { finding in
                Text(finding.item.category.title)
                    .foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 84, max: 130)
            .customizationID("category")

            TableColumn("修改日期", value: \.modifiedSortKey) { finding in
                Text(finding.item.lastModified?.formatted(date: .numeric, time: .omitted) ?? "—")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .width(min: 76, ideal: 92, max: 120)
            .customizationID("modified")

            // Last, and the only column without a maximum: it is the one that
            // gives up width when the inspector opens, so the numbers a user
            // sorts by never scroll out of view.
            TableColumn("说明") { finding in
                Text(finding.assessment?.whatItIs ?? finding.item.kindHint)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(finding.assessment?.consequence ?? finding.decision.rationale)
            }
            .width(min: 40, ideal: 240)
            .customizationID("description")
        }
        .contextMenu(forSelectionType: Finding.ID.self) { ids in
            contextMenu(for: ids)
        } primaryAction: { ids in
            // Double-click reveals rather than opens: these are caches, build
            // products and app leftovers, and "open" on most of them means
            // nothing useful.
            reveal(ids)
        }
        // Space to look before deciding, as in Finder. Read-only — Quick
        // Look never writes — and the arrow keys step through the selected
        // rows while it is open.
        .quickLookPreview($quickLookURL, in: selectedURLs)
        .onAppear { installSpaceMonitor() }
        .onDisappear { removeSpaceMonitor() }
    }

    // MARK: - Quick Look

    /// Space toggles Quick Look while a table has keyboard focus.
    ///
    /// A local event monitor rather than `onKeyPress`, which never sees the
    /// key: underneath, `Table` is an `NSTableView`, and that takes printable
    /// keys for type-select before SwiftUI is asked. The focus check keeps a
    /// space typed into the search field a space.
    private func installSpaceMonitor() {
        guard spaceMonitor.token == nil else { return }
        let model = self.model
        let rowSelection = $rowSelection
        let quickLookURL = $quickLookURL
        spaceMonitor.token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == 49,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty,
                  event.window?.firstResponder is NSTableView
            else { return event }
            if quickLookURL.wrappedValue != nil {
                quickLookURL.wrappedValue = nil
                return nil
            }
            let selected = rowSelection.wrappedValue
            guard let first = model.findings.first(where: { selected.contains($0.id) }) else {
                return event
            }
            quickLookURL.wrappedValue = first.item.url
            return nil
        }
    }

    private func removeSpaceMonitor() {
        if let token = spaceMonitor.token { NSEvent.removeMonitor(token) }
        spaceMonitor.token = nil
    }

    /// Selected rows' files, in table order.
    private var selectedURLs: [URL] {
        findings.filter { rowSelection.contains($0.id) }.map(\.item.url)
    }

    private func checkBinding(for finding: Finding) -> Binding<Bool> {
        Binding(
            get: { model.selection.contains(finding.id) },
            set: { _ in model.toggle(finding) }
        )
    }

    // MARK: - Context menu

    @ViewBuilder
    private func contextMenu(for ids: Set<Finding.ID>) -> some View {
        let targets = findings.filter { ids.contains($0.id) }
        let selectable = targets.filter(\.isSelectable)

        if !selectable.isEmpty {
            Button(selectable.count == 1 ? "勾选" : "勾选这 \(selectable.count) 项") {
                for finding in selectable where !model.selection.contains(finding.id) {
                    model.toggle(finding)
                }
            }
            Button(selectable.count == 1 ? "取消勾选" : "取消勾选这 \(selectable.count) 项") {
                for finding in selectable where model.selection.contains(finding.id) {
                    model.toggle(finding)
                }
            }
            Divider()
        }
        Button("快速查看") {
            quickLookURL = findings.first { ids.contains($0.id) }?.item.url
        }
        Button("在访达中显示") { reveal(ids) }
        Button("拷贝路径") {
            let paths = targets.map(\.item.path).joined(separator: "\n")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(paths, forType: .string)
        }
    }

    private func reveal(_ ids: Set<Finding.ID>) {
        let urls = findings.filter { ids.contains($0.id) }.map(\.item.url)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}

/// Icon, name and owner in one cell. A locked row shows a lock where the
/// category icon would be, so the reason it cannot be ticked is visible before
/// the user tries.
private struct NameCell: View {
    let finding: Finding

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: finding.isSelectable ? finding.item.category.symbolName : "lock.fill")
                .foregroundStyle(finding.isSelectable ? finding.item.category.tint : Color.secondary)
                .frame(width: 16)
                .help(finding.isSelectable ? finding.item.category.title : finding.decision.rationale)
            Text(finding.item.displayName)
                .lineLimit(1)
                .truncationMode(.middle)
            if let owner = finding.assessment?.attribution ?? finding.item.ownerHint?.label,
               owner != finding.item.displayName {
                Text(owner)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .opacity(finding.isSelectable ? 1 : 0.6)
    }
}

// MARK: - Sort keys

extension Finding {
    /// `KeyPathComparator` needs a `Comparable` value; the category's title is
    /// what the column shows, so it is what the column sorts by.
    var categorySortKey: String { item.category.title }

    /// Undated entries sort as oldest rather than being impossible to sort.
    var modifiedSortKey: Date { item.lastModified ?? .distantPast }
}

/// Holds an `NSEvent` monitor across view updates; a struct `@State` would
/// lose track of which monitor to remove.
private final class MonitorToken {
    var token: Any?
}
