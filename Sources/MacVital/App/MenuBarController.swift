import AppKit
import SwiftUI
import MacVitalKit

/// The status item: live network throughput, plus the numbers this app already
/// knows (free disk, quarantine size) one click away.
///
/// Deliberately not a second copy of the UI — the menu is a readout and a way
/// back to the window, nothing that removes files.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    /// Screen tools get their own item rather than rows in the speed menu:
    /// both the pen and screenshots are used while another app is in front.
    private var penItem: NSStatusItem?
    private let speeds: NetworkSpeedMonitor
    private weak var environment: AppEnvironment?

    private let downRow = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let upRow = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let diskRow = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let quarantineRow = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let penToggleRow = NSMenuItem(title: "开启屏幕画笔", action: nil, keyEquivalent: "")

    init(speeds: NetworkSpeedMonitor, environment: AppEnvironment) {
        self.speeds = speeds
        self.environment = environment
        super.init()
    }

    var isVisible: Bool { statusItem != nil }

    func show() {
        if statusItem != nil {
            // Re-applying settings should also heal a monitor whose timer was
            // stopped while its status item survived.
            speeds.start()
            render()
            return
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.imagePosition = .noImage
        item.menu = makeMenu()
        statusItem = item
        speeds.start()
        render()
    }

    func hide() {
        guard let statusItem else { return }
        NSStatusBar.system.removeStatusItem(statusItem)
        self.statusItem = nil
        speeds.stop()
    }

    // MARK: - Screen pen

    func showPenItem() {
        guard penItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "pencil.tip.crop.circle",
                                     accessibilityDescription: "快捷工具")
        item.button?.toolTip = "快捷工具 — 截图与屏幕画笔"
        item.menu = makeScreenToolsMenu()
        penItem = item
        refreshPenItem()
    }

    func hidePenItem() {
        guard let penItem else { return }
        NSStatusBar.system.removeStatusItem(penItem)
        self.penItem = nil
    }

    /// Fills the glyph while drawing is live, so the menu bar always says
    /// whether a click will land on the screen or in the app underneath.
    func refreshPenItem() {
        guard let button = penItem?.button, let pen = environment?.screenPen else { return }
        let name = pen.isActive ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle"
        button.image = NSImage(systemSymbolName: name, accessibilityDescription: "快捷工具")
        button.contentTintColor = pen.isActive ? NSColor.controlAccentColor : nil
        penToggleRow.title = pen.isActive ? "退出屏幕画笔" : "开启屏幕画笔"
        penToggleRow.state = pen.isActive ? .on : .off
    }

    @objc private func togglePen() {
        environment?.screenPen.toggle()
        refreshPenItem()
    }

    private func makeScreenToolsMenu() -> NSMenu {
        let menu = NSMenu()

        penToggleRow.target = self
        penToggleRow.action = #selector(togglePen)
        menu.addItem(penToggleRow)
        menu.addItem(.separator())

        let screenshot = NSMenuItem(title: "截图", action: nil, keyEquivalent: "")
        let screenshotMenu = NSMenu()
        for mode in ScreenshotService.Mode.allCases {
            let row = NSMenuItem(title: mode.title, action: #selector(captureScreen(_:)), keyEquivalent: "")
            row.target = self
            row.representedObject = mode.rawValue
            row.image = NSImage(systemSymbolName: mode.symbolName, accessibilityDescription: mode.title)
            screenshotMenu.addItem(row)
        }
        screenshot.submenu = screenshotMenu
        menu.addItem(screenshot)

        return menu
    }

    @objc private func captureScreen(_ sender: NSMenuItem) {
        guard let rawMode = sender.representedObject as? String,
              let mode = ScreenshotService.Mode(rawValue: rawMode),
              let environment else { return }

        let previousCapture = environment.screenshots.latest?.url
        let mainWindow = NSApp.windows.first { $0.isVisible && $0.canBecomeMain }

        Task {
            await environment.screenshots.capture(mode: mode, hiding: mainWindow)

            let hasNewCapture = environment.screenshots.latest?.url != previousCapture
            let hasError = environment.screenshots.errorMessage != nil
            guard hasNewCapture || hasError else { return }

            environment.page = .screenshot
            environment.showMainWindow()
        }
    }

    /// Called every time the monitor publishes. Cheap: two attributed strings.
    func render() {
        render(download: speeds.downloadRate, upload: speeds.uploadRate)
    }

    func render(download: Double, upload: Double) {
        guard let button = statusItem?.button else { return }
        button.attributedTitle = Self.title(
            download: download,
            upload: upload
        )
    }

    // MARK: - Title

    /// Two stacked lines at 9pt — the conventional shape for a throughput item,
    /// and the only way to fit both directions in the menu bar's 22pt height.
    private static func title(download: Double, upload: Double) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right
        paragraph.lineSpacing = -3.5
        paragraph.maximumLineHeight = 10

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .regular),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
            .baselineOffset: -1.5,
        ]
        return NSAttributedString(
            string: "↓ \(SpeedFormat.string(download))\n↑ \(SpeedFormat.string(upload))",
            attributes: attributes
        )
    }

    // MARK: - Menu

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self

        for row in [downRow, upRow, diskRow, quarantineRow] {
            row.isEnabled = false
            menu.addItem(row)
        }
        menu.insertItem(NSMenuItem.separator(), at: 2)
        menu.addItem(.separator())

        let open = NSMenuItem(title: "打开 PureMark", action: #selector(openWindow), keyEquivalent: "")
        open.target = self
        menu.addItem(open)

        let scan = NSMenuItem(title: "开始扫描", action: #selector(startScan), keyEquivalent: "")
        scan.target = self
        menu.addItem(scan)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        return menu
    }

    /// Refresh the readouts as the menu opens rather than every second — the
    /// disk measurement is a syscall and nobody is reading a closed menu.
    func menuWillOpen(_ menu: NSMenu) {
        downRow.title = "下载　\(SpeedFormat.string(speeds.downloadRate))"
        upRow.title = "上传　\(SpeedFormat.string(speeds.uploadRate))"

        // `DiskSpace.current()`, not a second implementation. This used to have
        // its own `freeDiskBytes()` querying the same key — two copies of one
        // question, free to drift apart on which volume or which capacity key
        // they ask about.
        if let snapshot = DiskSpace.current() {
            diskRow.title = "可用空间　\(ByteFormat.string(snapshot.free))"
        } else {
            diskRow.title = "可用空间　未知"
        }

        let quarantined = environment?.quarantineBytes ?? 0
        quarantineRow.title = quarantined > 0
            ? "隔离区　\(ByteFormat.string(quarantined))"
            : "隔离区　空"
    }

    // MARK: - Actions

    /// Raising through `NSApp.windows` is not enough once the window can
    /// actually be closed: with background residency the scene is torn down and
    /// there is nothing left to raise, so this has to go through the
    /// environment, which owns the scene's `openWindow` action.
    @objc private func openWindow() {
        environment?.showMainWindow()
    }

    @objc private func startScan() {
        openWindow()
        guard let environment else { return }
        Task { await environment.scanModel.startScan() }
    }
}
