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
    /// The pen gets its own item rather than a row in the speed menu: it is a
    /// toggle you reach for mid-presentation, and burying it two clicks deep
    /// defeats the point.
    private var penItem: NSStatusItem?
    private let speeds: NetworkSpeedMonitor
    private weak var environment: AppEnvironment?

    private let downRow = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let upRow = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let diskRow = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let quarantineRow = NSMenuItem(title: "", action: nil, keyEquivalent: "")

    init(speeds: NetworkSpeedMonitor, environment: AppEnvironment) {
        self.speeds = speeds
        self.environment = environment
        super.init()
    }

    var isVisible: Bool { statusItem != nil }

    func show() {
        guard statusItem == nil else { return }
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
                                     accessibilityDescription: "屏幕画笔")
        item.button?.toolTip = "屏幕画笔 — 点击开始，esc 退出"
        item.button?.target = self
        item.button?.action = #selector(togglePen)
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
        button.image = NSImage(systemSymbolName: name, accessibilityDescription: "屏幕画笔")
        button.contentTintColor = pen.isActive ? NSColor.controlAccentColor : nil
    }

    @objc private func togglePen() {
        environment?.screenPen.toggle()
        refreshPenItem()
    }

    /// Called every time the monitor publishes. Cheap: two attributed strings.
    func render() {
        guard let button = statusItem?.button else { return }
        button.attributedTitle = Self.title(
            download: speeds.downloadRate,
            upload: speeds.uploadRate
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

        let open = NSMenuItem(title: "打开 MacVital", action: #selector(openWindow), keyEquivalent: "")
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

        if let free = Self.freeDiskBytes() {
            diskRow.title = "可用空间　\(ByteFormat.string(free))"
        } else {
            diskRow.title = "可用空间　未知"
        }

        let quarantined = environment?.quarantineBytes ?? 0
        quarantineRow.title = quarantined > 0
            ? "隔离区　\(ByteFormat.string(quarantined))"
            : "隔离区　空"
    }

    private static func freeDiskBytes() -> Int64? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    // MARK: - Actions

    @objc private func openWindow() {
        NSApp.activate(ignoringOtherApps: true)
        // The single `Window` scene is already built; raising it is enough.
        for window in NSApp.windows where window.canBecomeMain {
            window.makeKeyAndOrderFront(nil)
            return
        }
    }

    @objc private func startScan() {
        openWindow()
        guard let environment else { return }
        Task { await environment.scanModel.startScan() }
    }
}
