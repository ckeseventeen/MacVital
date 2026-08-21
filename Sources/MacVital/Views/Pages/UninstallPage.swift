import SwiftUI
import MacVitalKit

/// The uninstaller, promoted from a sheet to a full page per the spec's
/// five-item navigation. The plan-building and rule evaluation are unchanged —
/// this is `UninstallViewModel` in a different frame.
struct UninstallPage: View {
    @EnvironmentObject private var environment: AppEnvironment
    @StateObject private var model: UninstallViewModel
    @State private var confirming = false
    /// Raised only after a graceful quit has visibly failed. Force-quitting is
    /// the one action here that can lose unsaved work, so it never happens as a
    /// side effect of the ordinary button.
    @State private var confirmingForceQuit = false

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
            if model.runningInstance != nil {
                Button("退出并卸载", role: .destructive) { Task { await model.quitAndUninstall() } }
                Button("仅卸载未占用的项目") { Task { await model.uninstall() } }
            } else {
                Button("移入隔离区", role: .destructive) { Task { await model.uninstall() } }
            }
            Button("取消", role: .cancel) {}
        } message: {
            if let running = model.runningInstance {
                Text("「\(running.localizedName ?? model.selectedApp?.name ?? "该 App")」正在运行。"
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
                // The verification result, not just a receipt. A re-plan ran
                // after the removal; either it came back with nothing — which
                // is what makes "卸载干净" a checkable statement rather than a
                // marketing one — or it names what is still there.
                VStack(alignment: .leading, spacing: 2) {
                    Label(summary, systemImage: "checkmark.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryLabel)
                        .lineLimit(2)
                    if model.isVerifiedClean {
                        Label("已复查：这个 App 的残留没有剩下任何一项", systemImage: "checkmark.seal.fill")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.success)
                    } else {
                        Label("复查后仍有 \(model.leftovers.count) 项残留，列在上方", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Theme.junk)
                    }
                }
            // "Still running" is the one lock the user can clear, so it gets an
            // action instead of a count. Everything else here is permanent and
            // there is nothing to offer.
            } else if let running = model.runningInstance, !model.inUseRows.isEmpty {
                Label("\(model.inUseRows.count) 项被占用：「\(running.localizedName ?? model.selectedApp?.name ?? "该 App")」正在运行",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.junk)

                Button(model.isPlanning ? "正在重新检测…" : "退出它并重试") {
                    Task { await model.quitRunningInstanceAndReplan() }
                }
                .controlSize(.small)
                .disabled(model.isPlanning || model.isRemoving)
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
                    .opacity(row.isSelectable ? 1 : 0.55)
                Text(row.candidate.item.abbreviatedPath)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.tertiaryLabel)
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
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.secondaryLabel)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 1)
                }
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
        // Dim what is unavailable, not the sentence explaining why. A blanket
        // 0.5 over the whole row made the new rationale line the faintest text
        // on screen.
        .contextMenu { Button("在访达中显示", action: reveal) }
    }
}
