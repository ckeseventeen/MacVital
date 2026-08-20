import SwiftUI
import MacVitalKit

/// Startup item management.
///
/// The whole page is a view onto three plist directories the cleaner's rule
/// catalog already covers, so "disable" reuses the quarantine pipeline rather
/// than shelling out to `launchctl`. That buys the one property that matters
/// here: everything is reversible for the retention window.
struct StartupPage: View {
    @EnvironmentObject private var environment: AppEnvironment
    @StateObject private var model: StartupViewModel
    @State private var confirming = false

    init(environment: AppEnvironment) {
        _model = StateObject(wrappedValue: StartupViewModel(environment: environment))
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 18) {
                PageHeader(title: "开机启动项", subtitle: subtitle) {
                    Button("刷新") { Task { await model.reload() } }
                        .buttonStyle(.bordered)
                        .disabled(model.isLoading)
                }
                controls
            }
            .padding(.horizontal, Theme.Metric.pagePaddingH)
            .padding(.top, Theme.Metric.pagePaddingV)
            .padding(.bottom, 18)

            Divider().overlay(Theme.separator)

            if model.isLoading {
                Spacer()
                ProgressView("正在读取启动项…").controlSize(.small)
                Spacer()
            } else if model.visibleRows.isEmpty {
                Spacer()
                emptyState
                Spacer()
            } else {
                list
            }

            Divider().overlay(Theme.separator)
            footer
        }
        .task { await model.reload() }
        // No error alert here on purpose. There used to be one bound to an
        // `errorMessage` that nothing ever assigned — a modal that could not
        // appear. Per-item failures come back in `outcome.skipped` and are
        // shown inline in the summary, which is both truthful and less
        // interruptive.
        .confirmationDialog("停用选中的 \(model.selection.count) 个启动项？", isPresented: $confirming, titleVisibility: .visible) {
            Button("停用", role: .destructive) { Task { await model.disableSelected() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("配置文件会移入隔离区，下次登录起不再自动运行。已在运行的进程不受影响，随时可以还原。")
        }
    }

    private var subtitle: String {
        if model.isLoading { return "正在读取…" }
        let total = model.rows.count
        return model.orphanCount > 0
            ? "\(total) 项 · 其中 \(model.orphanCount) 项指向的程序已不存在"
            : "\(total) 项 · 没有发现失效条目"
    }

    // MARK: - Controls

    private var controls: some View {
        HStack(spacing: 12) {
            Toggle("只看失效的", isOn: $model.showOnlyOrphaned)
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(.system(size: 13))

            if model.orphanCount > 0 {
                Button("选中全部失效项") { model.selectOrphaned() }
                    .buttonStyle(.link)
                    .font(.system(size: 13))
            }
            Button("全不选") { model.deselectAll() }
                .buttonStyle(.link)
                .font(.system(size: 13))
                .disabled(model.selection.isEmpty)

            Spacer()

            Label("Apple 自带的系统服务已排除", systemImage: "info.circle")
                .font(.system(size: 12))
                .foregroundStyle(Theme.tertiaryLabel)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            GlyphTile(systemImage: "power", tint: Theme.success, size: 48)
            Text(model.showOnlyOrphaned ? "没有失效的启动项" : "没有第三方启动项")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.label)
            Text("这台机器上没有需要处理的开机启动配置。")
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondaryLabel)
        }
    }

    // MARK: - List

    private var list: some View {
        List {
            ForEach(groupedRows, id: \.scope) { group in
                Section {
                    ForEach(group.rows) { row in
                        StartupRow(
                            row: row,
                            isChecked: model.selection.contains(row.id),
                            toggle: { model.toggle(row) },
                            reveal: { model.reveal(row) }
                        )
                    }
                } header: {
                    HStack(spacing: 8) {
                        Text(group.scope.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Theme.label)
                        if group.scope.requiresPrivilege {
                            Text("需要管理员授权")
                                .font(.system(size: 11))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(Theme.junk.opacity(0.14), in: Capsule())
                                .foregroundStyle(Theme.junk)
                        }
                        Spacer()
                        Text("\(group.rows.count)")
                            .font(.system(size: 12))
                            .monospacedDigit()
                            .foregroundStyle(Theme.secondaryLabel)
                    }
                    .textCase(nil)
                }
            }
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds()
    }

    private var groupedRows: [(scope: LoginItem.Scope, rows: [StartupViewModel.Row])] {
        [LoginItem.Scope.userAgent, .systemAgent, .daemon].compactMap { scope in
            let matching = model.visibleRows.filter { $0.item.scope == scope }
            return matching.isEmpty ? nil : (scope: scope, rows: matching)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 12) {
            if let summary = model.summary {
                Label(summary, systemImage: "checkmark.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryLabel)
                    .lineLimit(3)
            } else if model.needsHelper {
                Label("含系统级项目，需要先安装特权助手", systemImage: "key.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.junk)
            } else {
                Text("停用 = 把配置移入隔离区，不是删除，可还原")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryLabel)
            }

            Spacer()

            Text("已选 \(model.selection.count) 项")
                .font(.system(size: 13))
                .monospacedDigit()
                .foregroundStyle(Theme.secondaryLabel)

            Button {
                confirming = true
            } label: {
                if model.isRemoving {
                    ProgressView().controlSize(.small)
                } else {
                    Text("停用").font(.system(size: 14, weight: .medium)).padding(.horizontal, 8)
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

// MARK: - Icon

/// The owning app's real icon, with a warning badge when the target is gone.
///
/// `NSWorkspace.icon(forFile:)` hits the icon services cache, so this is cheap
/// enough to call per row without a separate async load.
private struct LoginItemIcon: View {
    let item: LoginItem

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let path = item.iconPath {
                Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                    .resizable()
                    .frame(width: 30, height: 30)
                    .opacity(item.isOrphaned ? 0.45 : 1)
            } else {
                GlyphTile(systemImage: "power", tint: Theme.accent, size: 30)
            }

            if item.isOrphaned {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.white, Theme.junk)
                    .background(Circle().fill(Theme.surface).frame(width: 13, height: 13))
                    .offset(x: 3, y: 3)
            }
        }
        .frame(width: 32, height: 32)
    }
}

// MARK: - Row

private struct StartupRow: View {
    let row: StartupViewModel.Row
    let isChecked: Bool
    let toggle: () -> Void
    let reveal: () -> Void

    var body: some View {
        HStack(spacing: 11) {
            Toggle("", isOn: Binding(get: { isChecked }, set: { _ in toggle() }))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .disabled(!row.isSelectable)
                .help(row.isSelectable ? "" : row.decision.rationale)

            LoginItemIcon(item: row.item)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.item.displayName)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.label)
                        .lineLimit(1)
                    if row.item.isOrphaned {
                        Text("程序已不存在")
                            .font(.system(size: 11))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Theme.junk.opacity(0.14), in: Capsule())
                            .foregroundStyle(Theme.junk)
                    }
                    if row.item.keepAlive {
                        Text("常驻")
                            .font(.system(size: 11))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Theme.well, in: Capsule())
                            .foregroundStyle(Theme.secondaryLabel)
                    }
                }
                Text(row.item.program.map { PathRedaction.abbreviate($0) } ?? row.item.label)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.tertiaryLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            if row.decision.admission != .allow {
                AdmissionBadge(decision: row.decision)
            }
        }
        .padding(.vertical, 2)
        .opacity(row.isSelectable ? 1 : 0.5)
        .contextMenu {
            Button("在访达中显示", action: reveal)
        }
    }
}
