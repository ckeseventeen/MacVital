import SwiftUI
import AppKit
import MacVitalKit

@main
struct MacVitalApp: App {
    static let mainWindowID = "main"

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // No custom `init()`: SwiftUI initialises property-wrapper defaults on the
    // main actor, which is what `AppEnvironment` and its view models require.
    @StateObject private var environment = AppEnvironment()

    var body: some Scene {
        Window("MacVital", id: Self.mainWindowID) {
            RootView()
                .environmentObject(environment)
                .environmentObject(environment.scanModel)
                .environmentObject(environment.screenPen)
                .environmentObject(environment.screenshots)
                .environmentObject(environment.recorder)
                .environmentObject(environment.live)
                .frame(minWidth: 1000, minHeight: 640)
                .preferredColorScheme(environment.settings.appearanceMode.colorScheme)
                .task { await environment.bootstrap() }
                // Re-probe whenever the app comes back to the front. The user
                // grants Full Disk Access in another process, so returning
                // here is the only signal that anything might have changed.
                .onReceive(NotificationCenter.default.publisher(
                    for: NSApplication.didBecomeActiveNotification
                )) { _ in
                    environment.permissions.refresh()
                }
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .toolbar) {
                Button("重新扫描") {
                    Task { await environment.scanModel.startScan() }
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(environment.scanModel.isScanning)
            }
        }

        Settings {
            SettingsView()
                .environmentObject(environment)
                .environmentObject(environment.settings)
                .environmentObject(environment.screenPen)
                .environmentObject(environment.screenshots)
                .environmentObject(environment.recorder)
                .environmentObject(environment.live)
                .frame(width: 560)
                .preferredColorScheme(environment.settings.appearanceMode.colorScheme)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// AppKit's lifecycle callbacks have no route to the SwiftUI environment,
    /// so the scene hands itself over once it exists. Weak: the delegate must
    /// not be what keeps the environment alive.
    @MainActor static weak var environment: AppEnvironment?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Stays `.regular` even when running headless. The Dock icon is the
        // one affordance that is always present — the status items are both
        // user-disablable, and an app with no window, no Dock tile and no menu
        // bar item is an app the user cannot get back to.
        NSApp.setActivationPolicy(.regular)
    }

    /// The whole point of background residency: closing the window is not a
    /// request to quit. The menu bar readout, the screen pen and the quarantine
    /// sweep all keep working. Cmd-Q still quits.
    @MainActor
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !(Self.environment?.settings.keepRunningInBackground ?? false)
    }

    /// Clicking the Dock icon with no window open.
    @MainActor
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { Self.environment?.showMainWindow() }
        return true
    }
}
