import SwiftUI
import AppKit
import MacVitalKit

@main
struct MacVitalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // No custom `init()`: SwiftUI initialises property-wrapper defaults on the
    // main actor, which is what `AppEnvironment` and its view models require.
    @StateObject private var environment = AppEnvironment()

    var body: some Scene {
        Window("MacVital", id: "main") {
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
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
