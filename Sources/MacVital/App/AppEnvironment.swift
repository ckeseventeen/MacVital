import AppKit
import Foundation
import MacVitalKit
import SwiftUI

/// Wiring. Owns the long-lived objects and hands them to the view models.
@MainActor
@Observable
final class AppEnvironment {
    let settings: AppSettings
    let permissions = PermissionsCoordinator()
    let rules = RuleIndex()
    let quarantine: QuarantineStore
    let helper = HelperClient()

    var helperStatus: HelperStatus = .notRegistered
    var quarantineBytes: Int64 = 0
    var quarantineRecords: [QuarantineRecord] = []

    private(set) var quarantineRoot: String

    /// The scan view model lives here rather than in the `App` struct so the
    /// app has exactly one environment instance and no custom `App.init()`.
    @ObservationIgnored lazy var scanModel: ScanViewModel = ScanViewModel(environment: self)

    let networkSpeeds = NetworkSpeedMonitor()
    let screenPen = ScreenPenController()
    let whiteboard = WhiteboardViewModel()
    let screenshots = ScreenshotService()
    let recorder = ScreenRecorder()
    let live = LiveBroadcaster()
    @ObservationIgnored private lazy var menuBar = MenuBarController(speeds: networkSpeeds, environment: self)

    /// Which page the shell is showing.
    var page: AppPage = .dashboard
    var diskSpace: DiskSpace.Snapshot?
    /// Sheet state lives here rather than in a view: the dashboard's quick
    /// actions and the junk page's footer both raise them from different
    /// branches of the tree.
    var showConfirm = false
    var showQuarantine = false

    init() {
        // The retention window is a user setting, and the confirm sheet quotes
        // it back to them ("N 天后才清除"). Passed as a closure, not a value:
        // reading it once here meant changing the setting did nothing until the
        // next launch, while the sheet went on quoting the new number.
        let settings = AppSettings()
        let store = QuarantineStore(retentionDaysProvider: { AppSettings.currentRetentionDays() })
        self.settings = settings
        self.quarantine = store
        self.quarantineRoot = store.root.path

        // There used to be a Combine subscription here forwarding
        // `permissions.objectWillChange` to this object's, because a nested
        // `ObservableObject` does not propagate: a view reading
        // `environment.permissions.fullDiskAccess` rendered once and never
        // heard about a change, and the permission banner sat on `.unknown`
        // for the life of the process.
        //
        // Observation tracks the access path itself, so that read now
        // registers a dependency on `permissions.fullDiskAccess` directly. The
        // workaround existed only because of the old model's defect.
    }

    var coordinator: CleanupCoordinator {
        CleanupCoordinator(rules: rules, store: quarantine, helper: helper)
    }

    func makeScanEngine() -> ScanEngine {
        ScanEngine(
            rules: rules,
            advisor: CompositeAdvisor(primary: settings.makeAdvisor()),
            quarantineRoot: quarantineRoot
        )
    }

    // MARK: - Main window

    /// Reopening a closed `Window` scene needs the scene's own `openWindow`
    /// action. Once the window is closed the scene is torn down and it is no
    /// longer in `NSApp.windows`, so the AppKit route — `makeKeyAndOrderFront`
    /// — has nothing to raise. `RootView` registers this while it exists.
    @ObservationIgnored private var mainWindowOpener: (() -> Void)?

    func registerMainWindowOpener(_ open: @escaping () -> Void) {
        mainWindowOpener = open
    }

    /// Bring the app back to the front, recreating the window if it was closed.
    func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        // Still open, just buried: raising it keeps scroll position and any
        // in-progress scan on screen, which recreating the scene would not.
        if let window = NSApp.windows.first(where: { $0.canBecomeMain && $0.isVisible }) {
            window.makeKeyAndOrderFront(nil)
            return
        }
        mainWindowOpener?()
    }

    // MARK: - Launch

    /// Bootstrap is driven by the main window's `.task`, and with background
    /// residency that window can be closed and reopened any number of times.
    /// Re-running the launch sequence on every reopen would re-sweep the
    /// quarantine and re-probe permissions for no reason.
    @ObservationIgnored private var didBootstrap = false

    func bootstrap() async {
        guard !didBootstrap else { return }
        didBootstrap = true

        permissions.refresh()
        helperStatus = helper.status()
        applyMenuBarSetting()
        refreshDiskSpace()
        try? await quarantine.prepare()

        // The 7-day timer runs here, on every launch. A quarantine store that
        // only empties when the user opens a particular screen is a store that
        // silently grows forever.
        let purged = await coordinator.sweepExpired()
        if purged > 0 {
            Log.app.info("purged \(purged, privacy: .public) expired quarantine records on launch")
        }
        await refreshQuarantine()
    }

    // MARK: - Menu bar

    /// Called on launch and whenever the setting changes. The status item owns
    /// the monitor's lifetime — no point sampling interface counters once a
    /// second for a readout nobody is showing.
    func applyMenuBarSetting() {
        // The status items are AppKit, so they are told about changes
        // explicitly rather than observed. Both callbacks hand over the value
        // the item renders, after it has been stored — never a "something is
        // about to change" signal that would leave the item one sample behind.
        if settings.showMenuBarSpeed {
            menuBar.show()
            networkSpeeds.onSample = { [weak self] download, upload in
                self?.menuBar.render(download: download, upload: upload)
            }
        } else {
            networkSpeeds.onSample = nil
            menuBar.hide()
        }

        if settings.showMenuBarPen {
            menuBar.showPenItem()
            screenPen.onActiveChange = { [weak self] in self?.menuBar.refreshPenItem() }
        } else {
            screenPen.onActiveChange = nil
            screenPen.stop()
            menuBar.hidePenItem()
        }
    }

    func refreshDiskSpace() {
        diskSpace = DiskSpace.current()
    }

    func refreshQuarantine() async {
        quarantineRecords = await quarantine.allRecords()
        quarantineBytes = await quarantine.totalBytes()
    }

    // MARK: - Privileged helper

    /// Only ever called from an explicit user action — registering pops a
    /// system dialog, and popping one unprompted is how apps get uninstalled.
    func installHelper() {
        do {
            try helper.register()
        } catch {
            Log.app.error("helper registration failed: \(error.localizedDescription, privacy: .public)")
        }
        helperStatus = helper.status()
        if helperStatus == .requiresApproval {
            helper.openApprovalSettings()
        }
    }

    func removeHelper() async {
        try? await helper.uninstall()
        helperStatus = helper.status()
    }

    func refreshHelperStatus() {
        helperStatus = helper.status()
    }
}
