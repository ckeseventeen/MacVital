import AppKit
import Combine
import Foundation
import MacVitalKit
import SwiftUI

/// Wiring. Owns the long-lived objects and hands them to the view models.
@MainActor
final class AppEnvironment: ObservableObject {
    let settings: AppSettings
    let permissions = PermissionsCoordinator()
    let rules = RuleIndex()
    let quarantine: QuarantineStore
    let helper = HelperClient()

    @Published var helperStatus: HelperStatus = .notRegistered
    @Published var quarantineBytes: Int64 = 0
    @Published var quarantineRecords: [QuarantineRecord] = []

    private(set) var quarantineRoot: String

    /// The scan view model lives here rather than in the `App` struct so the
    /// app has exactly one environment instance and no custom `App.init()`.
    lazy var scanModel: ScanViewModel = ScanViewModel(environment: self)

    let networkSpeeds = NetworkSpeedMonitor()
    let screenPen = ScreenPenController()
    let screenshots = ScreenshotService()
    let recorder = ScreenRecorder()
    let live = LiveBroadcaster()
    private lazy var menuBar = MenuBarController(speeds: networkSpeeds, environment: self)
    private var speedObservation: AnyCancellable?
    private var penObservation: AnyCancellable?
    private var permissionObservation: AnyCancellable?

    /// Which page the shell is showing.
    @Published var page: AppPage = .dashboard
    @Published var diskSpace: DiskSpace.Snapshot?
    /// Sheet state lives here rather than in a view: the dashboard's quick
    /// actions and the junk page's footer both raise them from different
    /// branches of the tree.
    @Published var showConfirm = false
    @Published var showQuarantine = false

    init() {
        // The retention window is a user setting, and the confirm sheet quotes
        // it back to them ("N 天后才清除"). Read it here rather than letting the
        // store fall back to its 7-day default, or the promise is a lie.
        let settings = AppSettings()
        let store = QuarantineStore(retentionDays: settings.retentionDays)
        self.settings = settings
        self.quarantine = store
        self.quarantineRoot = store.root.path

        // `permissions` is a nested ObservableObject, and SwiftUI does not
        // propagate those: a view observing `AppEnvironment` and reading
        // `environment.permissions.fullDiskAccess` renders once and then never
        // hears about a change. That is exactly what happened — the permission
        // banner captured `.unknown` at first render and stayed there for the
        // life of the process, so re-probing, granting access and relaunching
        // all appeared to do nothing.
        //
        // Forwarding here rather than injecting `permissions` as its own
        // environment object because three views read it through
        // `environment`, and a missing `.environmentObject()` at any scene
        // root is a crash rather than a stale banner.
        permissionObservation = permissions.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
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
    private var mainWindowOpener: (() -> Void)?

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
    private var didBootstrap = false

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
        if settings.showMenuBarSpeed {
            menuBar.show()
            if speedObservation == nil {
                speedObservation = networkSpeeds.objectWillChange
                    .sink { [weak self] _ in
                        // objectWillChange fires before the new value lands.
                        Task { @MainActor in self?.menuBar.render() }
                    }
            }
        } else {
            speedObservation = nil
            menuBar.hide()
        }

        if settings.showMenuBarPen {
            menuBar.showPenItem()
            if penObservation == nil {
                penObservation = screenPen.objectWillChange
                    .sink { [weak self] _ in
                        Task { @MainActor in self?.menuBar.refreshPenItem() }
                    }
            }
        } else {
            penObservation = nil
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
