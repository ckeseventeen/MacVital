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
            .sheet(isPresented: Bindable(environment).showQuarantine) {
                QuarantineView(isPresented: Bindable(environment).showQuarantine, environment: environment)
            }
            // 编辑 › 撤销「移入隔离区」, the way every Mac app offers to take
            // back the last thing it did. Registered on the window's undo
            // manager, so ⌘Z and the menu item come from the system.
            .onChange(of: model.lastCleanup?.id) { _, id in
                guard id != nil, let undoManager else { return }
                // Only the newest cleanup can be undone — the model keeps one.
                // Stacking an entry per cleanup left 撤销「移入隔离区」 in the
                // Edit menu after the first ⌘Z, pointing at nothing.
                undoManager.removeAllActions(withTarget: model)
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
///    made. The re-check button is gone for that reason; relaunching is the
///    check, and it is the prominent action.
struct PermissionBanner: View {
    @Environment(AppEnvironment.self) private var environment

    private var permissions: PermissionsCoordinator { environment.permissions }
    private var isDenied: Bool { permissions.fullDiskAccess == .denied }

    var body: some View {
        // One row, whatever the width: the text truncates rather than wraps,
        // and the full sentence is in the tooltip. Beside an open inspector
        // the banner gets half the window, and wrapping there broke a
        // sentence over four lines next to the buttons.
        HStack(spacing: 11) {
            Image(systemName: isDenied ? "lock.shield.fill" : "questionmark.circle.fill")
                .foregroundStyle(isDenied ? Theme.junk : Theme.secondaryLabel)
                .accessibilityHidden(true)
            message
                .layoutPriority(-1)
            Spacer(minLength: 8)
            // Two actions, in the order they are taken. There used to be a
            // third, 重新检测, and a disclosure explaining why it never
            // changed anything: the grant only reaches a process at launch,
            // so the relaunch is the check.
            HStack(spacing: 8) {
                Button("前往设置") { permissions.openSystemSettings() }
                Button("授权后重启") { permissions.relaunch() }
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
            .fixedSize()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
        .background((isDenied ? Theme.junk : Color.secondary).opacity(0.09))
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
        .help(headline + "\n" + explanation + "\n授权在 App 启动时才生效，所以勾选之后需要重启一次。")
        .accessibilityElement(children: .combine)
    }
}
