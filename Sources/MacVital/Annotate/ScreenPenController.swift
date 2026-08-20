import AppKit
import SwiftUI

/// Draw on top of whatever is on screen.
///
/// One window per display, each holding a dimming layer and an annotation
/// canvas, plus a floating palette. The palette is its own window rather than a
/// view inside the canvas so that clicking a colour never lays down a stroke.
@MainActor
final class ScreenPenController: NSObject, ObservableObject {

    /// The reference tool's 7-colour palette.
    static let palette: [NSColor] = [
        NSColor(srgbRed: 1.00, green: 0.23, blue: 0.19, alpha: 1),  // #FF3B30
        NSColor(srgbRed: 1.00, green: 0.58, blue: 0.00, alpha: 1),  // #FF9500
        NSColor(srgbRed: 1.00, green: 0.80, blue: 0.00, alpha: 1),  // #FFCC00
        NSColor(srgbRed: 0.16, green: 0.78, blue: 0.25, alpha: 1),  // #28C840
        NSColor(srgbRed: 0.22, green: 0.54, blue: 0.87, alpha: 1),  // #378ADD
        NSColor(srgbRed: 0.33, green: 0.29, blue: 0.72, alpha: 1),  // #534AB7
        NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1),  // #1D1D1F
    ]
    static let widths: [CGFloat] = [2, 4, 7, 12]

    @Published private(set) var isActive = false
    @Published var tool: AnnotationTool = .pen { didSet { applyTool() } }
    @Published var colorIndex = 0 { didSet { applyTool() } }
    @Published var widthIndex = 1 { didSet { applyTool() } }
    @Published var focusMode: FocusMode = .off { didSet { applyFocus() } }
    @Published private(set) var canUndo = false

    private var canvases: [AnnotationCanvasView] = []
    private var focusLayers: [FocusOverlayView] = []
    private var windows: [ScreenPenWindow] = []
    private var paletteWindow: NSPanel?
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var maskDragOrigin: CGPoint?

    var currentColor: Color { Color(nsColor: Self.palette[colorIndex]) }

    // MARK: - Lifecycle

    func toggle() { isActive ? stop() : start() }

    func start() {
        guard !isActive, !NSScreen.screens.isEmpty else { return }

        for screen in NSScreen.screens {
            let window = ScreenPenWindow(screen: screen)
            let frame = NSRect(origin: .zero, size: screen.frame.size)

            let container = NSView(frame: frame)
            container.autoresizingMask = [.width, .height]

            let focus = FocusOverlayView(frame: frame)
            focus.autoresizingMask = [.width, .height]
            container.addSubview(focus)

            let canvas = AnnotationCanvasView(frame: frame)
            canvas.autoresizingMask = [.width, .height]
            canvas.onChange = { [weak self] in self?.refreshUndoState() }
            container.addSubview(canvas)

            window.contentView = container
            window.orderFrontRegardless()

            windows.append(window)
            canvases.append(canvas)
            focusLayers.append(focus)
        }
        windows.first?.makeKey()

        applyTool()
        applyFocus()
        showPalette()
        installMonitors()
        isActive = true
    }

    func stop() {
        guard isActive else { return }
        for monitor in [keyMonitor, mouseMonitor].compactMap({ $0 }) {
            NSEvent.removeMonitor(monitor)
        }
        keyMonitor = nil
        mouseMonitor = nil

        paletteWindow?.orderOut(nil)
        paletteWindow = nil
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        canvases.removeAll()
        focusLayers.removeAll()
        isActive = false
        canUndo = false
        focusMode = .off
        NSCursor.arrow.set()
    }

    // MARK: - Tools

    func undo() { canvases.forEach { $0.undo() } }
    func redo() { canvases.forEach { $0.redo() } }
    func clear() { canvases.forEach { $0.clear() } }

    private func applyTool() {
        for canvas in canvases {
            canvas.tool = tool
            canvas.style = AnnotationStyle(
                color: Self.palette[colorIndex],
                lineWidth: Self.widths[widthIndex]
            )
            canvas.window?.invalidateCursorRects(for: canvas)
        }
    }

    private func applyFocus() {
        for layer in focusLayers { layer.mode = focusMode }
        // A mask starts empty; without a starting rect the screen would go
        // fully black until the user happens to drag one out.
        if focusMode == .mask {
            for (index, layer) in focusLayers.enumerated() where layer.maskRect == .zero {
                let size = windows[safe: index]?.frame.size ?? .zero
                layer.maskRect = CGRect(
                    x: size.width * 0.25, y: size.height * 0.25,
                    width: size.width * 0.5, height: size.height * 0.5
                )
            }
        }
    }

    /// Strictly `canUndo`. It used to be `canUndo || !isEmpty`, which lit the
    /// undo button for a canvas holding strokes it could no longer undo —
    /// pressing it did nothing, with no way to tell that from a missed click.
    private func refreshUndoState() {
        canUndo = canvases.contains { $0.document.canUndo }
    }

    // MARK: - Monitors

    private func installMonitors() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isActive else { return event }
            switch event.keyCode {
            case 53:  // esc — the only guaranteed way out of a screen-filling layer
                self.stop()
                return nil
            case 6 where event.modifierFlags.contains(.command):  // cmd-z / cmd-shift-z
                event.modifierFlags.contains(.shift) ? self.redo() : self.undo()
                return nil
            default:
                return event
            }
        }

        // The spotlight has to track the pointer even while the canvas above it
        // is handling a drag, so it listens on the window's event stream rather
        // than through the view hierarchy.
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .leftMouseDown, .leftMouseUp]) { [weak self] event in
            guard let self, self.isActive, self.focusMode != .off else { return event }
            self.updateFocus(for: event)
            return event
        }
        for window in windows { window.acceptsMouseMovedEvents = true }
    }

    private func updateFocus(for event: NSEvent) {
        guard let window = event.window as? ScreenPenWindow,
              let index = windows.firstIndex(of: window),
              let layer = focusLayers[safe: index] else { return }
        let point = layer.convert(event.locationInWindow, from: nil)

        switch focusMode {
        case .spotlight:
            layer.spotlightCenter = point
        case .mask:
            // Only the select tool drags the mask; otherwise dragging would
            // fight with drawing.
            guard tool == .select else { return }
            switch event.type {
            case .leftMouseDown:
                maskDragOrigin = point
            case .leftMouseDragged:
                guard let origin = maskDragOrigin else { return }
                layer.maskRect = CGRect(
                    x: min(origin.x, point.x), y: min(origin.y, point.y),
                    width: abs(point.x - origin.x), height: abs(point.y - origin.y)
                )
            case .leftMouseUp:
                maskDragOrigin = nil
            default:
                break
            }
        case .off:
            break
        }
    }

    // MARK: - Palette

    private func showPalette() {
        guard let screen = NSScreen.main else { return }
        let hosting = NSHostingView(rootView: PenPalette(controller: self))
        hosting.frame = NSRect(x: 0, y: 0, width: 660, height: 62)

        let panel = NSPanel(
            contentRect: hosting.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hosting
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .init(Int(CGShieldingWindowLevel()) + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isMovableByWindowBackground = true

        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(
            x: frame.midX - hosting.frame.width / 2,
            y: frame.maxY - hosting.frame.height - 24
        ))
        panel.orderFrontRegardless()
        paletteWindow = panel
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

/// The floating toolbar: tools, colours, widths, focus mode, undo, clear, exit.
private struct PenPalette: View {
    @ObservedObject var controller: ScreenPenController

    private let tools: [AnnotationTool] = [.select, .pen, .highlighter, .rectangle, .ellipse, .arrow, .text, .eraser]

    var body: some View {
        HStack(spacing: 12) {
            toolGroup
            Divider().frame(height: 20)
            colorGroup
            Divider().frame(height: 20)
            widthGroup
            Divider().frame(height: 20)
            focusGroup
            Divider().frame(height: 20)
            actionGroup
        }
        .padding(.horizontal, 16)
        .frame(height: 62)
        .glassPanel(cornerRadius: 20)
    }

    private var toolGroup: some View {
        HStack(spacing: 3) {
            ForEach(tools) { candidate in
                PaletteButton(
                    systemImage: candidate.symbolName,
                    isOn: controller.tool == candidate,
                    help: candidate.title
                ) {
                    controller.tool = candidate
                }
            }
        }
    }

    private var colorGroup: some View {
        HStack(spacing: 7) {
            ForEach(Array(ScreenPenController.palette.enumerated()), id: \.offset) { index, color in
                Button {
                    controller.colorIndex = index
                } label: {
                    Circle()
                        .fill(Color(nsColor: color))
                        .frame(width: 17, height: 17)
                        .overlay(Circle().strokeBorder(.white, lineWidth: controller.colorIndex == index ? 2 : 0))
                        .overlay(Circle().strokeBorder(.black.opacity(0.18), lineWidth: 0.5))
                        .scaleEffect(controller.colorIndex == index ? 1.18 : 1)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var widthGroup: some View {
        HStack(spacing: 5) {
            ForEach(Array(ScreenPenController.widths.enumerated()), id: \.offset) { index, width in
                Button {
                    controller.widthIndex = index
                } label: {
                    Circle()
                        .fill(controller.widthIndex == index ? controller.currentColor : Color.secondary)
                        .frame(width: width + 3, height: width + 3)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var focusGroup: some View {
        HStack(spacing: 3) {
            ForEach(FocusMode.allCases) { mode in
                PaletteButton(
                    systemImage: mode.symbolName,
                    isOn: controller.focusMode == mode,
                    help: "\(mode.title) — \(mode.detail)"
                ) {
                    controller.focusMode = mode
                }
            }
        }
    }

    private var actionGroup: some View {
        HStack(spacing: 3) {
            PaletteButton(systemImage: "arrow.uturn.backward", isOn: false, help: "撤销（⌘Z）") {
                controller.undo()
            }
            PaletteButton(systemImage: "arrow.uturn.forward", isOn: false, help: "重做（⇧⌘Z）") {
                controller.redo()
            }
            PaletteButton(systemImage: "trash", isOn: false, help: "清空") {
                controller.clear()
            }
            PaletteButton(systemImage: "xmark", isOn: false, help: "退出画笔（esc）") {
                controller.stop()
            }
        }
    }
}

private struct PaletteButton: View {
    let systemImage: String
    let isOn: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14))
                .foregroundStyle(isOn ? Color.white : Color.primary)
                .frame(width: 26, height: 26)
                .background(
                    isOn ? Theme.accent : Color.clear,
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
