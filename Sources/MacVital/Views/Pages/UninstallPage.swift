import SwiftUI
import MacVitalKit

/// The uninstaller, promoted from a sheet to a full page per the spec's
/// five-item navigation. The plan-building and rule evaluation are unchanged —
/// this is `UninstallViewModel` in a different frame.
struct UninstallPage: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var model: UninstallViewModel
    @State private var confirming = false
    /// Raised only after a graceful quit has visibly failed. Force-quitting is
    /// the one action here that can lose unsaved work, so it never happens as a
    /// side effect of the ordinary button.
    @State private var confirmingForceQuit = false

    /// The environment is passed explicitly rather than read from
    /// `@EnvironmentObject`: the view model must be constructed at `init` time
    /// and environment objects are not available that early.
    init(environment: AppEnvironment) {
        _model = State(initialValue: UninstallViewModel(environment: environment))
    }

    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                appList
                    .frame(minWidth: 220, idealWidth: 260, maxWidth: 340)
                // Explicit ideal widths on both panes: left to themselves, a
                // list of long paths reports its one-line width as its ideal,
                // and split views size their panes from ideals.
                planPane
                    .frame(minWidth: 360, idealWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
            }
            footer
        }
        .navigationSubtitle(model.apps.isEmpty ? "" : "\(model.apps.count) 个应用")
        .searchable(text: $model.query, placement: .toolbar, prompt: "搜索应用")
        .toolbar { toolbar }
        .task { model.loadApps() }
        // Quitting the app being uninstalled happens *outside* this window, so
        // coming back to it is the moment to re-check. Without this the plan
        // keeps reporting a process that exited minutes ago, and the lock looks
        // permanent when it is not.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            Task { await model.replan() }
        }
        // No error alert here on purpose. There used to be one bound to an
        // `errorMessage` that nothing ever assigned — a modal that could not
        // appear. Per-item failures come back in `outcome.skipped` and are
        // shown inline in the summary, which is both truthful and less
        // interruptive.
        .confirmationDialog(
            "确认卸载「\(model.selectedApp?.name ?? "")」？",
            isPresented: $confirming,
            titleVisibility: .visible
        ) {
            // When the target app is up, quitting is a precondition rather than
            // a separate errand — so it becomes the primary action instead of a
            // hint in the footer the user has to notice first.
            if !model.blockingTargets.isEmpty {
                Button("退出并卸载", role: .destructive) { Task { await model.quitAndUninstall() } }
                Button("仅卸载未占用的项目") { Task { await model.uninstall() } }
            } else {
                Button("移入隔离区", role: .destructive) { Task { await model.uninstall() } }
            }
            Button("取消", role: .cancel) {}
        } message: {
            if !model.blockingTargets.isEmpty {
                Text("「\(blockerNames)」正在运行。"
                     + "边运行边删会留下残留 —— 它退出时会把偏好设置和容器重新写回去。\n\n"
                     + "将先请它退出（有未保存内容时它会向你确认），退出后再移动 \(model.selection.count) 项，"
                     + "共 \(ByteFormat.string(model.selectedBytes))。文件先进入隔离区，随时可以还原。")
            } else {
                Text("将移动 \(model.selection.count) 项，共 \(ByteFormat.string(model.selectedBytes))。文件先进入隔离区，随时可以还原。")
            }
        }
        // Its own confirmation, and deliberately not reachable from the one
        // above: force-quitting is the only action in this app that can destroy
        // work the user has not saved, so it names what it is about to kill and
        // asks separately.
        .confirmationDialog(
            "强制结束并卸载？",
            isPresented: $confirmingForceQuit,
            titleVisibility: .visible
        ) {
            Button("强制结束并卸载", role: .destructive) {
                Task { await model.forceQuitAndUninstall() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(forceQuitWarning)
        }
    }

    /// Built outside the view builder: assembled inline it was a single
    /// expression the type checker gave up on.
    private var forceQuitWarning: String {
        var text = "将强制结束：\(model.stubbornTargets.joined(separator: "、"))。\n\n"
        text += "强制结束不给程序保存的机会，未保存的内容会直接丢失，正在写入的文件也可能损坏。"
        text += "只有在它已经没有响应、或你确定没有未保存内容时才这么做。"

        let relaunching = model.relaunchingBlockers
        if !relaunching.isEmpty {
            text += "\n\n注意：\(relaunching.joined(separator: "、"))"
            text += " 由启动项托管（KeepAlive），结束后 launchd 会立刻重新启动。"
            text += "先在「开机启动项」里停用对应条目，卸载才会彻底。"
        }
        return text
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            Button {
                model.loadApps()
                Task { await model.replan() }
            } label: {
                Label("重新载入", systemImage: "arrow.clockwise")
            }
            .help("重新读取已安装的应用")

            Button {
                guard let app = model.selectedApp else { return }
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.path)])
            } label: {
                Label("在访达中显示", systemImage: "folder")
            }
            .help("在访达中显示这个应用")
            .disabled(model.selectedApp == nil)
        }
    }

    // MARK: - App list

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
                    .frame(width: 24, height: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.name)
                        .lineLimit(1)
                    Text(app.bundleIdentifier)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.vertical, 2)
            .tag(app.bundleIdentifier)
        }
        .listStyle(.inset)
        .overlay {
            if model.apps.isEmpty {
                ProgressView().controlSize(.small)
            } else if model.visibleApps.isEmpty {
                ContentUnavailableView.search(text: model.query)
            }
        }
    }

    // MARK: - Plan

    @ViewBuilder
    private var planPane: some View {
        if let app = model.selectedApp {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.path))
                        .resizable()
                        .frame(width: 36, height: 36)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(app.name)
                            .font(.title3.weight(.semibold))
                        Text(model.isPlanning
                             ? "正在查找相关文件…"
                             : "\(model.rows.count) 项 · 共 \(ByteFormat.string(model.totalBytes))")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Spacer()
                    if model.runningInstance != nil {
                        Label("正在运行", systemImage: "circle.fill")
                            .font(.callout)
                            .foregroundStyle(.green)
                            .labelStyle(RunningLabelStyle())
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                Divider()

                if model.isPlanning && model.rows.isEmpty {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                                    if group.kind.carriesUserData {
                                        Text("含个人数据，默认不勾选")
                                            .foregroundStyle(Theme.junk)
                                    }
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
            ContentUnavailableView {
                Label("选择要卸载的应用", systemImage: "app.badge.checkmark")
            } description: {
                Text("会一并列出它散落在系统各处的配置、容器、缓存和登录项。")
            }
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

    // MARK: - Footer

    /// What happened, or what is in the way — above the action bar rather
    /// than squeezed into it, because these are sentences and some of them
    /// carry their own button.
    @ViewBuilder
    private var status: some View {
        if let summary = model.summary {
            // The verification result, not just a receipt. A re-plan ran
            // after the removal; either it came back with nothing — which
            // is what makes "卸载干净" a checkable statement rather than a
            // marketing one — or it names what is still there.
            VStack(alignment: .leading, spacing: 3) {
                Label(summary, systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
                if model.isVerifiedClean {
                    Label("已复查：这个 App 的残留没有剩下任何一项", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(Theme.success)
                } else {
                    Label("复查后仍有 \(model.leftovers.count) 项残留，列在上方", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.junk)
                }
                forceQuitButton
            }
        // "Still running" is the one lock the user can clear, so it gets an
        // action instead of a count. Everything else here is permanent and
        // there is nothing to offer.
        //
        // Whoever holds the files, not only the app itself: a Finder
        // extension, an updater or a login-item agent keeps its bundle
        // locked after the main app has quit, and this used to fall through
        // to "locked by safety rules" with nothing to press.
        } else if hasBlockers {
            HStack(spacing: 10) {
                Label("\(model.inUseRows.count) 项被占用：「\(blockerNames)」正在运行",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.junk)
                Spacer(minLength: 8)
                Button(model.isPlanning ? "正在重新检测…" : "退出它并重试") {
                    Task { await model.quitRunningInstanceAndReplan() }
                }
                .disabled(model.isPlanning || model.isRemoving)
                forceQuitButton
            }
        } else if !model.deniedRows.isEmpty {
            Label("\(model.deniedRows.count) 项被安全规则锁定", systemImage: "lock.fill")
                .foregroundStyle(.secondary)
        } else if model.needsHelper {
            Label("含系统目录项目，需要先安装特权助手", systemImage: "key.fill")
                .foregroundStyle(Theme.junk)
        }
    }

    /// The way into the force-quit confirmation.
    ///
    /// The dialog and the view model's whole escalation path existed, and the
    /// failure message even told the user to use 「强制结束」, but nothing on
    /// screen opened it — a graceful quit that was refused was a dead end.
    /// It appears only after that refusal, never before, and it opens the
    /// confirmation that names what will be killed rather than acting itself.
    @ViewBuilder
    private var forceQuitButton: some View {
        if model.quitWasRefused, !model.stubbornTargets.isEmpty {
            Button("强制结束并卸载…", role: .destructive) {
                confirmingForceQuit = true
            }
            .disabled(model.isPlanning || model.isRemoving)
        }
    }

    /// Something the user can quit is holding files in this plan.
    private var hasBlockers: Bool {
        !model.inUseRows.isEmpty && !model.blockingTargets.isEmpty
    }

    private var blockerNames: String {
        model.blockingTargets.map(\.name).joined(separator: "、")
    }

    private var hasStatus: Bool {
        model.summary != nil
            || hasBlockers
            || !model.deniedRows.isEmpty
            || model.needsHelper
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            if hasStatus {
                status
                    .font(.callout)
                    .controlSize(.small)
                    // Sentences take the width they are given and never ask
                    // for more — see `permissionBannerInset`.
                    .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                Divider()
            }
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("已选 \(ByteFormat.string(model.selectedBytes))")
                        .font(.headline)
                        .monospacedDigit()
                    Text("\(model.selection.count) 项 · 先移入隔离区，随时可以还原")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Menu("选择") {
                    Button("全选") { model.selectAll() }
                    Button("全不选") { model.deselectAll() }
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
                        Text("卸载…")
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

/// A small status dot before the text, the way Activity Monitor and System
/// Settings mark something live.
private struct RunningLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.imageScale(.small).font(.system(size: 7))
            configuration.title.foregroundStyle(.secondary)
        }
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
                .accessibilityLabel("卸载 \(row.candidate.item.displayName)")

            VStack(alignment: .leading, spacing: 1) {
                Text(row.candidate.item.displayName)
                    .lineLimit(1)
                    .opacity(row.isSelectable ? 1 : 0.55)
                Text(row.candidate.item.abbreviatedPath)
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .opacity(row.isSelectable ? 1 : 0.55)

                // The engine always explains itself, and "已锁定" alone is not
                // that explanation. Hiding the reason in a hover tooltip meant
                // the one row the user most wants explained — the one they
                // cannot select — was the one row saying least. Most of these
                // are "quit the app first", which is actionable the moment it
                // is legible.
                if !row.isSelectable {
                    Text(row.decision.rationale)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .padding(.top, 1)
                }
            }

            Spacer(minLength: 8)

            if row.decision.admission != .allow {
                AdmissionBadge(decision: row.decision)
            }
            Text(ByteFormat.string(row.candidate.item.sizeBytes))
                .monospacedDigit()
                .foregroundStyle(isChecked ? Theme.junk : .secondary)
                .frame(width: 70, alignment: .trailing)
        }
        .padding(.vertical, 1)
        // Dim what is unavailable, not the sentence explaining why. A blanket
        // 0.5 over the whole row made the new rationale line the faintest text
        // on screen.
        .contextMenu { Button("在访达中显示", action: reveal) }
    }
}
