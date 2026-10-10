import SwiftUI
import MacVitalKit

/// The menu bar.
///
/// A Mac app is driven from its menus as much as its window: every command is
/// discoverable there, every common one has a shortcut, and the shortcut is
/// printed next to it so the user can learn it. This app had one menu item of
/// its own (重新扫描). Everything else was reachable only by finding the right
/// button on the right page.
struct AppCommands: Commands {
    let environment: AppEnvironment

    private var scan: ScanViewModel { environment.scanModel }

    var body: some Commands {
        // 前往 — one shortcut per page, in sidebar order. Finder's Go menu is
        // the model; ⌘1–⌘8 is what sidebar apps use for jumping between
        // top-level sections.
        CommandMenu("前往") {
            ForEach(Array(AppPage.allCases.enumerated()), id: \.element) { index, page in
                Button(page.title) { environment.page = page }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
        }

        // 显示 → after the toolbar items.
        CommandGroup(after: .toolbar) {
            Button("重新扫描") {
                environment.page = .junk
                Task { await scan.startScan() }
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(scan.isScanning || scan.isCleaning)

            Button("停止扫描") { scan.cancelScan() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!scan.isScanning)

            Divider()

            Button("隔离区…") { environment.showQuarantine = true }
                .keyboardShortcut("k", modifiers: [.command, .shift])
        }
    }
}
