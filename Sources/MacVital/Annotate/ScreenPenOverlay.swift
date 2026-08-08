import AppKit

/// Borderless, transparent, above everything including full-screen apps.
///
/// `canBecomeKey` has to be overridden: a borderless window refuses key status
/// by default, and without it the Escape key never reaches us — leaving the
/// user under a screen-filling layer with no way out.
final class ScreenPenWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        // Above the menu bar and the Dock, and present on every Space so the
        // drawing does not vanish when the user switches desktops.
        level = .init(Int(CGShieldingWindowLevel()))
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        setFrame(screen.frame, display: true)
    }
}

/// How the screen is dimmed around the point of interest.
enum FocusMode: String, CaseIterable, Identifiable {
    case off
    case spotlight
    case mask

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "关闭"
        case .spotlight: return "聚光灯"
        case .mask: return "遮罩"
        }
    }

    var symbolName: String {
        switch self {
        case .off: return "circle.slash"
        case .spotlight: return "flashlight.on.fill"
        case .mask: return "rectangle.dashed"
        }
    }

    var detail: String {
        switch self {
        case .off: return "不遮挡"
        case .spotlight: return "跟随光标的圆形亮区"
        case .mask: return "拖出一块矩形亮区"
        }
    }
}

/// The dimming layer. Sits under the annotation canvas in the same window, so
/// the user can draw inside the lit area without the spotlight eating clicks.
///
/// Implemented as a filled rect with the lit shape subtracted via
/// `evenOdd` — one path, one fill, no image masks and no per-frame compositing.
final class FocusOverlayView: NSView {
    var mode: FocusMode = .off { didSet { needsDisplay = true } }
    var dimming: CGFloat = 0.62 { didSet { needsDisplay = true } }
    var spotlightRadius: CGFloat = 130 { didSet { needsDisplay = true } }
    var spotlightCenter: CGPoint = .zero { didSet { if mode == .spotlight { needsDisplay = true } } }
    var maskRect: CGRect = .zero { didSet { if mode == .mask { needsDisplay = true } } }

    override var isFlipped: Bool { false }
    /// Never takes a click — the canvas above it owns all interaction.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard mode != .off else { return }

        let path = NSBezierPath(rect: bounds)
        switch mode {
        case .spotlight:
            path.appendOval(in: CGRect(
                x: spotlightCenter.x - spotlightRadius,
                y: spotlightCenter.y - spotlightRadius,
                width: spotlightRadius * 2,
                height: spotlightRadius * 2
            ))
        case .mask:
            guard maskRect.width > 1, maskRect.height > 1 else { return }
            path.appendRoundedRect(maskRect.standardized, xRadius: 8, yRadius: 8)
        case .off:
            return
        }
        path.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(dimming).setFill()
        path.fill()
    }
}
