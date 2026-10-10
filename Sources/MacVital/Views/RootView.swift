import SwiftUI
import MacVitalKit

/// Hosts the shell and every sheet. The shell itself is layout only — sheet
/// state lives on `AppEnvironment` because more than one page raises them.
struct RootView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(ScanViewModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        // The page title is set inside the split view's detail column, where
        // the toolbar reads it from.
        AppShell()
            // Hand the AppKit side what it cannot reach on its own: the
            // environment (for the lifecycle callbacks) and the scene's
            // `openWindow` (the only way to rebuild a closed `Window`).
            .onAppear {
                AppDelegate.environment = environment
                environment.registerMainWindowOpener {
                    openWindow(id: MacVitalApp.mainWindowID)
                }
            }
            .sheet(isPresented: Bindable(environment).showConfirm) {
                ConfirmSheet(isPresented: Bindable(environment).showConfirm)
                    .environment(model)
                    .environment(environment)
            }
            .sheet(isPresented: Bindable(environment).showQuarantine) {
                QuarantineView(isPresented: Bindable(environment).showQuarantine, environment: environment)
            }
            // 编辑 › 撤销「移入隔离区」, the way every Mac app offers to take
            // back the last thing it did. Registered on the window's undo
            // manager, so ⌘Z and the menu item come from the system.
            .onChange(of: model.lastCleanup?.id) { _, id in
                guard id != nil, let undoManager else { return }
                undoManager.registerUndo(withTarget: model) { model in
                    Task { @MainActor in await model.undoLastCleanup() }
                }
                undoManager.setActionName("移入隔离区")
            }
            .alert(
                "部分项目未能还原",
                isPresented: Binding(
                    get: { model.undoReport != nil },
                    set: { if !$0 { model.undoReport = nil } }
                )
            ) {
                Button("查看隔离区") {
                    model.undoReport = nil
                    environment.showQuarantine = true
                }
                Button("好", role: .cancel) { model.undoReport = nil }
            } message: {
                Text((model.undoReport ?? "") + "\n\n它们还在隔离区里，可以稍后手动还原。")
            }
            .alert(
                "扫描出错",
                isPresented: Binding(
                    get: { model.errorMessage != nil },
                    set: { if !$0 { model.errorMessage = nil } }
                )
            ) {
                Button("好") { model.errorMessage = nil }
            } message: {
                Text(model.errorMessage ?? "")
            }
    }
}

// MARK: - Permission banner

extension View {
    /// Pins the Full Disk Access banner to the top of this view, under the
    /// toolbar, while the permission is missing.
    ///
    /// The shell applies it around every page. A page that carries an
    /// `.inspector` turns that off and applies it to its own content column
    /// instead: the inspector splits the detail area and lays each side out
    /// against the toolbar on its own, so a banner stacked above the whole
    /// split pushed the content column down without it noticing, and it
    /// still left a toolbar's height of empty space at its top.
    func permissionBannerInset(isEnabled: Bool = true) -> some View {
        modifier(PermissionBannerInset(isEnabled: isEnabled))
    }
}

private struct PermissionBannerInset: ViewModifier {
    @Environment(AppEnvironment.self) private var environment
    let isEnabled: Bool

    func body(content: Content) -> some View {
        VStack(spacing: 0) {
            if isEnabled, environment.permissions.fullDiskAccess != .granted {
                PermissionBanner()
                    // Ideal width zero: the banner takes whatever width the
                    // page has and never asks for more. Inside a page with an
                    // inspector it sits in a split view pane, and the split
                    // view sizes its panes from their ideal widths. The
                    // banner's ideal is its whole sentence on one line plus
                    // three buttons — wider than a default-sized window can
                    // give that pane beside the inspector — and AppKit kept
                    // re-solving the split until it terminated the app
                    // ("more Update Constraints in Window passes than there
                    // are views in the window").
                    .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity)
                Divider()
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Shown while Full Disk Access is missing — or while the app cannot tell.
///
/// Two things this banner must not do, both of which earlier versions did:
///
/// 1. **Claim knowledge it does not have.** `.unknown` and `.denied` are
///    worded differently, because a machine where every probe was merely
///    absent used to get told flatly that the permission was missing.
/// 2. **Offer an action that cannot work.** Full Disk Access is bound at
///    process launch, so re-probing can never observe a grant the user just
///    made. "Re-check" is still here — pressing it and seeing nothing change
///    is the honest outcome — but the banner now says why, and relaunching is
///    the prominent action rather than one hidden behind having visited
///    Settings first.
struct PermissionBanner: View {
    @Environment(AppEnvironment.self) private var environment

    private var permissions: PermissionsCoordinator { environment.permissions }
    private var isDenied: Bool { permissions.fullDiskAccess == .denied }

    /// The explanation is collapsed until asked for.
    ///
    /// Both notes below are things the user genuinely needs at the moment they
    /// hit them — that a relaunch is required, and that an ad-hoc build's grant
    /// dies on every rebuild — so neither can be cut. But left open they are
    /// roughly a hundred and fifty words of documentation nailed permanently
    /// across the top of every page, and they pushed the actual content of the
    /// overview a fifth of the way down the window. A headline, the buttons,
    /// and a way to ask why.
    @State private var showingDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // One row, whatever the width: the text truncates rather than
            // wraps, and the full sentence is in the tooltip and behind the
            // disclosure button. Beside an open inspector the banner gets
            // half the window, and wrapping there broke a sentence over four
            // lines next to three buttons.
            HStack(spacing: 11) {
                icon
                message
                    .layoutPriority(-1)
                Spacer(minLength: 8)
                actions
            }

            if isDenied, showingDetail {
                BannerNote(
                    "授权后必须重启 App 才会生效 —— macOS 只在进程启动时授予这个权限，"
                    + "所以在当前进程里点「重新检测」不会变化，这不是检测失败。"
                    + (permissions.lastCheckedAt.map {
                        " 上次检测 " + $0.formatted(date: .omitted, time: .standard) + "，仍未获得。"
                    } ?? "")
                )

                // Only worth saying on a build that has no stable identity for
                // TCC to key on —用证书签过名的构建授权本来就能跨重编译保留，
                // 在那里说这段话只会把人推去做无谓的移除重加。
                if permissions.grantsExpireOnRebuild {
                    BannerNote(
                        "这是 ad-hoc 签名的本地构建：没有证书可以绑定，macOS 只能按可执行文件的哈希记住授权，"
                        + "而每次重新编译哈希都会变。如果设置里已经有 PureMark 却依然显示未获得，"
                        + "请先用「−」把它移除，再重新添加当前这份 /Applications/PureMark.app。"
                        + "改用 make build-selfsigned 可以一劳永逸。",
                        icon: "exclamationmark.triangle.fill"
                    )
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
        .background((isDenied ? Theme.junk : Color.secondary).opacity(0.09))
    }

    private var icon: some View {
        Image(systemName: isDenied ? "lock.shield.fill" : "questionmark.circle.fill")
            .foregroundStyle(isDenied ? Theme.junk : Theme.secondaryLabel)
            .accessibilityHidden(true)
    }

    private var headline: String {
        isDenied ? "未获得「完整磁盘访问权限」" : "无法确认是否已获得「完整磁盘访问权限」"
    }

    private var explanation: String {
        isDenied
            ? "~/Library 下的绝大部分内容不可见，扫描结果会严重偏少。"
            : "扫描仍会正常进行；如果结果明显偏少，多半是缺这个权限。"
    }

    private var message: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(headline)
                .font(.body.weight(.medium))
            Text(explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .truncationMode(.tail)
        .help(headline + "\n" + explanation)
        .accessibilityElement(children: .combine)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button("重新检测") { permissions.refresh() }
            Button("前往设置") { permissions.openSystemSettings() }
            Button("授权后重启") { permissions.relaunch() }
                .buttonStyle(.borderedProminent)

            if isDenied {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { showingDetail.toggle() }
                } label: {
                    Image(systemName: showingDetail ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(showingDetail ? "收起说明" : "授权了还是不行？")
                .accessibilityLabel(showingDetail ? "收起说明" : "显示说明")
            }
        }
        .controlSize(.small)
        .fixedSize()
    }
}

/// A secondary explanatory line under the banner headline.
private struct BannerNote: View {
    let text: String
    var icon: String = "info.circle"

    init(_ text: String, icon: String = "info.circle") {
        self.text = text
        self.icon = icon
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icon)
                .font(.caption)
                .accessibilityHidden(true)
            Text(text)
                .font(.subheadline)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
        .padding(.leading, 25)
    }
}

// MARK: - Cleanup summary

/// Shown as an overlay on the junk page after a run.
struct CleanupSummaryView: View {
    let summary: ScanViewModel.CleanupSummary
    @Environment(ScanViewModel.self) private var model
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.undoManager) private var undoManager
    @State private var showSkipped = false

    var body: some View {
        VStack(spacing: 15) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 52))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Theme.success)
                .accessibilityHidden(true)
                .padding(.bottom, 4)

            Text("已移入隔离区 \(ByteFormat.string(summary.quarantinedBytes))")
                .font(.largeTitle.weight(.semibold))
                .monospacedDigit()

            // Says "N 天后释放", not "已回收". The quarantine store is on the
            // same volume, so nothing has been given back yet — and a user who
            // checks their free space right now will find it unchanged.
            Text("\(summary.removedCount) 项。隔离区在同一块磁盘上，"
                 + "\(environment.settings.retentionDays) 天后自动删除，届时才会真正释放空间。")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)

            if !summary.skipped.isEmpty {
                DisclosureGroup(isExpanded: $showSkipped) {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(summary.skipped, id: \.self) { line in
                            Text(line)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
                } label: {
                    Label("\(summary.skipped.count) 项被跳过", systemImage: "exclamationmark.triangle")
                }
                .frame(maxWidth: 420)
            }

            HStack(spacing: 10) {
                Button(model.isUndoing ? "正在还原…" : "撤销") {
                    // Taken here rather than through ⌘Z, so the menu item
                    // registered for it would undo nothing.
                    undoManager?.removeAllActions(withTarget: model)
                    Task { await model.undoLastCleanup() }
                }
                .help("把这次移入隔离区的文件放回原处（⌘Z）")
                .disabled(model.lastCleanup == nil || model.isUndoing)
                Button("查看隔离区") { environment.showQuarantine = true }
                Button("完成") { model.dismissSummary() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            .padding(.top, 4)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
