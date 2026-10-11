import SwiftUI
import MacVitalKit

/// Startup item management.
///
/// The whole page is a view onto three plist directories the cleaner's rule
/// catalog already covers, so "disable" reuses the quarantine pipeline rather
/// than shelling out to `launchctl`. That buys the one property that matters
/// here: everything is reversible for the retention window.
struct StartupPage: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var model: StartupViewModel
    @State private var confirming = false
    @State private var searchText = ""
    /// The row whose process refused a graceful quit. Set only after one has
    /// been tried and failed.
    @State private var forceTarget: StartupViewModel.Row?

    init(environment: AppEnvironment) {
        _model = State(initialValue: StartupViewModel(environment: environment))
    }

    var body: some View {
        VStack(spacing: 0) {
            blockedNotice
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .navigationSubtitle(subtitle)
        .searchable(text: $searchText, placement: .toolbar, prompt: "搜索启动项")
        .toolbar { toolbar }
        .task { await model.reload() }
        // Instead of a refresh button: whatever changed it — an app installed
        // or removed, a process quit — happened outside this window.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            Task { await model.reload(preservingSelection: true) }
        }
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
        .confirmationDialog(
            "强制结束「\(forceTarget?.item.displayName ?? "")」？",
            isPresented: Binding(get: { forceTarget != nil }, set: { if !$0 { forceTarget = nil } }),
            titleVisibility: .visible
        ) {
            Button("强制结束", role: .destructive) {
                guard let row = forceTarget else { return }
                forceTarget = nil
                Task { await model.stop(row, force: true) }
            }
            Button("取消", role: .cancel) { forceTarget = nil }
        } message: {
            Text("它没有响应退出请求。强制结束不给程序保存的机会，未保存的内容会直接丢失，"
                 + "正在写入的文件也可能损坏。")
        }
        .alert("已停止", isPresented: Binding(
            get: { model.stopMessage != nil },
            set: { if !$0 { model.clearStopMessage() } }
        )) {
            Button("好") { model.clearStopMessage() }
        } message: {
            Text(model.stopMessage ?? "")
        }
    }

    private var subtitle: String {
        if model.isLoading { return "正在读取…" }
        var parts = ["\(model.rows.count) 项"]
        if model.orphanCount > 0 { parts.append("\(model.orphanCount) 项已失效") }
        parts.append("已排除 Apple 系统服务")
        return parts.joined(separator: " · ")
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Toggle(isOn: $model.showOnlyOrphaned) {
                Label("只看失效的", systemImage: "exclamationmark.triangle")
            }
            .help("只显示指向的程序已不存在的启动项")
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if model.isLoading && model.rows.isEmpty {
            ProgressView("正在读取启动项…")
                .controlSize(.small)
        } else if model.visibleRows.isEmpty {
            ContentUnavailableView {
                Label(model.showOnlyOrphaned ? "没有失效的启动项" : "没有第三方启动项",
                      systemImage: "power")
            } description: {
                Text("这台机器上没有需要处理的开机启动配置。")
            }
        } else if displayedRows.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else {
            list
        }
    }

    private var displayedRows: [StartupViewModel.Row] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return model.visibleRows }
        return model.visibleRows.filter { row in
            row.item.displayName.localizedStandardContains(query)
                || row.item.label.localizedStandardContains(query)
                || (row.item.program?.localizedStandardContains(query) ?? false)
        }
    }

    /// Says once, in the open, what the rows can only say in a tooltip.
    @ViewBuilder
    private var blockedNotice: some View {
        if let reason = model.uniformBlocker {
            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Image(systemName: "lock.circle.fill")
                    .foregroundStyle(Theme.junk)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("这些条目都不能在当前构建里操作")
                        .font(.body.weight(.medium))
                    Text(reason)
                        .foregroundStyle(.secondary)
                    // The door. Finder can write where this app cannot — it
                    // asks for an administrator password and does it — and
                    // without saying so the page is a wall with no way past.
                    Text("访达可以：把 plist 拖进废纸篓时系统会要一次密码。"
                         + "代价是它进的是废纸篓而不是隔离区，没有一键还原。")
                        .foregroundStyle(.secondary)
                    Button("在访达中打开该目录") { model.revealBlockedDirectory() }
                        .buttonStyle(.link)
                        .padding(.top, 1)
                }
                .font(.callout)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            // Sentences take the width they are given and never ask for more
            // — see `permissionBannerInset`.
            .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity, alignment: .leading)
            .background(Theme.junk.opacity(0.09))
            Divider()
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
                            reveal: { model.reveal(row) },
                            stop: {
                                Task {
                                    // A refusal is the only thing that unlocks
                                    // the harsher option, and it asks first.
                                    if await model.stop(row) == false { forceTarget = row }
                                }
                            }
                        )
                    }
                } header: {
                    HStack(spacing: 8) {
                        Text(group.scope.title)
                        if group.scope.requiresPrivilege {
                            Tag("需要管理员授权", tint: Theme.junk)
                        }
                        Spacer()
                        Text("\(group.rows.count)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .textCase(nil)
                }
            }
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds()
    }

    private var groupedRows: [(scope: LoginItem.Scope, rows: [StartupViewModel.Row])] {
        let rows = displayedRows
        return [LoginItem.Scope.userAgent, .systemAgent, .daemon].compactMap { scope in
            let matching = rows.filter { $0.item.scope == scope }
            return matching.isEmpty ? nil : (scope: scope, rows: matching)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            if model.summary != nil || model.needsHelper {
                Group {
                    if let summary = model.summary {
                        Label(summary, systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                    } else {
                        Label("含系统级项目，需要先安装特权助手", systemImage: "key.fill")
                            .foregroundStyle(Theme.junk)
                    }
                }
                .font(.callout)
                .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                Divider()
            }
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("已选 \(model.selection.count) 项")
                        .font(.headline)
                        .monospacedDigit()
                    Text("停用 = 把配置移入隔离区，不是删除，可还原")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Menu("选择") {
                    Button("选中全部失效项") { model.selectOrphaned() }
                        .disabled(model.orphanCount == 0)
                    Button("全不选") { model.deselectAll() }
                        .disabled(model.selection.isEmpty)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(model.rows.isEmpty || model.isRemoving)

                Button {
                    confirming = true
                } label: {
                    if model.isRemoving {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("停用…")
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.selection.isEmpty || model.isRemoving)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .background(.bar)
    }
}

/// A small tinted capsule — state words beside a name.
private struct Tag: View {
    let text: String
    let tint: Color

    init(_ text: String, tint: Color) {
        self.text = text
        self.tint = tint
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(tint.opacity(0.14), in: Capsule())
            .foregroundStyle(tint)
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
                    .font(.caption)
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
    let stop: () -> Void

    var body: some View {
        HStack(spacing: 11) {
            Toggle("", isOn: Binding(get: { isChecked }, set: { _ in toggle() }))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .disabled(!row.isSelectable)
                .help(row.isSelectable ? "" : row.decision.rationale)
                .accessibilityLabel("停用 \(row.item.displayName)")

            LoginItemIcon(item: row.item)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.item.displayName)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    if row.item.isOrphaned {
                        Tag("程序已不存在", tint: Theme.junk)
                    }
                    if row.item.keepAlive {
                        Tag("常驻", tint: .secondary)
                    }
                }
                Text(row.item.program.map { PathRedaction.abbreviate($0) } ?? row.item.label)
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            // Offered only where it would actually work. A `KeepAlive` job is
            // owned by launchd: kill it and it is back in about a second, and
            // quarantining the plist does not change that either — the job
            // stays loaded until the next login. A button there would do
            // nothing visible, which is worse than not having one.
            if row.canStopNow {
                Button("停止", action: stop)
                    .controlSize(.small)
                    .help("结束正在运行的进程。这不影响它下次登录是否启动。")
            } else if row.running != nil, row.stoppingWouldNotStick {
                Text("常驻，需重新登录")
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .help("launchd 会立刻重新启动它，所以现在结束它没有意义。"
                          + "停用之后重新登录，它才不会再起来。")
            }

            if !row.isSelectable {
                Button("访达", action: reveal)
                    .buttonStyle(.link)
                    .font(.callout)
                    .help("在访达中显示这个 plist。把它拖进废纸篓时系统会要一次密码。")
            }

            if row.decision.admission != .allow {
                AdmissionBadge(decision: row.decision)
            }
        }
        .padding(.vertical, 2)
        .opacity(row.isSelectable ? 1 : 0.5)
        .contextMenu {
            Button("在访达中显示", action: reveal)
            if row.canStopNow {
                Button("停止运行中的进程", action: stop)
            }
        }
    }
}
