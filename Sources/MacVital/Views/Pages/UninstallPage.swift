import SwiftUI
import MacVitalKit

/// The uninstaller, promoted from a sheet to a full page per the spec's
/// five-item navigation. The plan-building and rule evaluation are unchanged —
/// this is `UninstallViewModel` in a different frame.
struct UninstallPage: View {
    @EnvironmentObject private var environment: AppEnvironment
    @StateObject private var model: UninstallViewModel
    @State private var confirming = false

    /// The environment is passed explicitly rather than read from
    /// `@EnvironmentObject`: the view model must be constructed at `init` time
    /// and environment objects are not available that early.
    init(environment: AppEnvironment) {
        _model = StateObject(wrappedValue: UninstallViewModel(environment: environment))
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(
                    title: "卸载应用",
                    subtitle: "\(model.apps.count) 个应用 · 选中后一并清除它散落各处的配置"
                )
                searchField
            }
            .padding(.horizontal, Theme.Metric.pagePaddingH)
            .padding(.top, Theme.Metric.pagePaddingV)
            .padding(.bottom, 18)

            Divider().overlay(Theme.separator)

            HSplitView {
                appList.frame(minWidth: 250, idealWidth: 290, maxWidth: 360)
                planPane.frame(minWidth: 380)
            }

            Divider().overlay(Theme.separator)
            footer
        }
        .task { model.loadApps() }
        .alert(
            "卸载失败",
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
            "确认卸载「\(model.selectedApp?.name ?? "")」？",
            isPresented: $confirming,
            titleVisibility: .visible
        ) {
            Button("移入隔离区", role: .destructive) { Task { await model.uninstall() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将移动 \(model.selection.count) 项，共 \(ByteFormat.string(model.selectedBytes))。文件先进入隔离区，随时可以还原。")
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondaryLabel)
            TextField("搜索应用", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Theme.well, in: RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
        .frame(maxWidth: 340)
    }

    private var appList: some View {
        List(model.visibleApps, id: \.bundleIdentifier, selection: Binding(
            get: { model.selectedApp?.bundleIdentifier },
            set: { id in
                guard let app = model.apps.first(where: { $0.bundleIdentifier == id }) else { return }
                Task { await model.select(app) }
            }
        )) { app in
            HStack(spacing: 9) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                    .resizable()
                    .frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.name)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.label)
                        .lineLimit(1)
                    Text(app.bundleIdentifier)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.tertiaryLabel)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.vertical, 2)
            .tag(app.bundleIdentifier)
        }
        .listStyle(.inset)
    }

    @ViewBuilder
    private var planPane: some View {
        if let app = model.selectedApp {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                        .resizable()
                        .frame(width: 38, height: 38)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(app.name)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(Theme.label)
                        Text("\(model.rows.count) 项 · 共 \(ByteFormat.string(model.totalBytes))")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondaryLabel)
                    }
                    Spacer()
                    Button("全选") { model.selectAll() }.buttonStyle(.link).font(.system(size: 13))
                    Button("全不选") { model.deselectAll() }.buttonStyle(.link).font(.system(size: 13))
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 12)

                Divider().overlay(Theme.separator)

                if model.isPlanning {
                    Spacer()
                    ProgressView("正在查找相关文件…").controlSize(.small)
                    Spacer()
                } else {
                    List {
                        ForEach(groupedRows, id: \.kind) { group in
                            Section {
                                ForEach(group.rows) { row in
                                    UninstallRow(
                                        row: row,
                                        isChecked: model.selection.contains(row.id),
                                        toggle: { model.toggle(row) },
                                        reveal: { model.revealInFinder(row) }
                                    )
                                }
                            } header: {
                                HStack(spacing: 7) {
                                    Text(group.kind.title)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(Theme.label)
                                    if group.kind.carriesUserData {
                                        Text("含个人数据，默认不勾选")
                                            .font(.system(size: 11))
                                            .foregroundStyle(Theme.junk)
                                    }
                                    Spacer()
                                }
                                .textCase(nil)
                            }
                        }
                    }
                    .listStyle(.inset)
                    .alternatingRowBackgrounds()
                }
            }
        } else {
            VStack(spacing: 10) {
                GlyphTile(systemImage: "square.grid.2x2", tint: Color(hex: 0x534AB7), size: 46)
                Text("从左侧选择要卸载的应用")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.secondaryLabel)
                Text("会一并列出它散落在系统各处的配置、容器、缓存和登录项。")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.tertiaryLabel)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 280)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var groupedRows: [(kind: AppUninstallPlanner.Kind, rows: [UninstallViewModel.Row])] {
        let order: [AppUninstallPlanner.Kind] = [
            .bundle, .support, .container, .cache, .preference, .state, .launchItem, .log,
        ]
        return order.compactMap { kind in
            let matching = model.rows.filter { $0.candidate.kind == kind }
            return matching.isEmpty ? nil : (kind: kind, rows: matching)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let summary = model.summary {
                Label(summary, systemImage: "checkmark.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryLabel)
                    .lineLimit(2)
            } else if !model.deniedRows.isEmpty {
                Label("\(model.deniedRows.count) 项被安全规则锁定", systemImage: "lock.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.tertiaryLabel)
            } else if model.needsHelper {
                Label("含系统目录项目，需要先安装特权助手", systemImage: "key.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.junk)
            }

            Spacer()

            Text("已选 \(model.selection.count) 项 · \(ByteFormat.string(model.selectedBytes))")
                .font(.system(size: 13))
                .monospacedDigit()
                .foregroundStyle(Theme.secondaryLabel)

            Button {
                confirming = true
            } label: {
                if model.isRemoving {
                    ProgressView().controlSize(.small)
                } else {
                    Text("卸载").font(.system(size: 14, weight: .medium)).padding(.horizontal, 8)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(Theme.junk)
            .disabled(model.selection.isEmpty || model.isRemoving)
        }
        .padding(.horizontal, Theme.Metric.pagePaddingH)
        .padding(.vertical, Theme.Metric.barPaddingV)
        .glassChrome()
    }
}

struct UninstallRow: View {
    let row: UninstallViewModel.Row
    let isChecked: Bool
    let toggle: () -> Void
    let reveal: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { isChecked }, set: { _ in toggle() }))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .disabled(!row.isSelectable)
                .help(row.isSelectable ? "" : row.decision.rationale)

            VStack(alignment: .leading, spacing: 1) {
                Text(row.candidate.item.displayName)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.label)
                    .lineLimit(1)
                Text(row.candidate.item.abbreviatedPath)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.tertiaryLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            if row.decision.admission != .allow {
                AdmissionBadge(decision: row.decision)
            }
            Text(ByteFormat.string(row.candidate.item.sizeBytes))
                .font(.system(size: 13))
                .monospacedDigit()
                .foregroundStyle(isChecked ? Theme.junk : Theme.secondaryLabel)
                .frame(width: 70, alignment: .trailing)
        }
        .padding(.vertical, 1)
        .opacity(row.isSelectable ? 1 : 0.5)
        .contextMenu { Button("在访达中显示", action: reveal) }
    }
}
