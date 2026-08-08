import AppKit

/// The document: an ordered list of objects plus an undo stack.
///
/// Undo is snapshot-based rather than command-based. Annotation documents hold
/// tens of objects, not thousands, so copying the array is free — and a
/// snapshot cannot get out of step with the model the way a hand-written
/// inverse operation can.
final class AnnotationDocument {
    private(set) var objects: [AnnotationObject] = []
    private var undoStack: [[AnnotationObject]] = []
    private var redoStack: [[AnnotationObject]] = []

    var isEmpty: Bool { objects.isEmpty }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Call *before* a mutation, once per user-visible action.
    func checkpoint() {
        undoStack.append(objects)
        redoStack.removeAll()
        if undoStack.count > 100 { undoStack.removeFirst() }
    }

    func append(_ object: AnnotationObject) { objects.append(object) }

    /// Swap the whole content, discarding history. Used when the whiteboard
    /// switches boards — undo belongs to the board you are on, and carrying a
    /// previous board's stack across would let ⌘Z resurrect marks from a page
    /// the user is no longer looking at.
    func load(_ replacement: [AnnotationObject]) {
        objects = replacement
        undoStack.removeAll()
        redoStack.removeAll()
    }

    func remove(id: UUID) { objects.removeAll { $0.id == id } }

    func replace(_ object: AnnotationObject) {
        guard let index = objects.firstIndex(where: { $0.id == object.id }) else { return }
        objects[index] = object
    }

    func object(at point: CGPoint) -> AnnotationObject? {
        // Topmost first: the last drawn is the one on top.
        objects.reversed().first { $0.hitTest(point) }
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(objects)
        objects = previous
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(objects)
        objects = next
    }

    func clear() {
        guard !objects.isEmpty else { return }
        checkpoint()
        objects.removeAll()
    }
}

/// Renders an `AnnotationDocument` and edits it with the current tool.
///
/// Used in two places with no changes: transparent over the whole screen, and
/// opaque over a captured screenshot. Everything it knows about is the document
/// and the tool — never where the pixels underneath came from.
final class AnnotationCanvasView: NSView {
    let document = AnnotationDocument()

    var tool: AnnotationTool = .pen { didSet { updateCursor(); if tool != .select { selectedID = nil; needsDisplay = true } } }
    var style = AnnotationStyle(color: .systemRed, lineWidth: 4)

    /// A still image drawn under the annotations. Nil for the screen overlay.
    var backdrop: NSImage?

    var onChange: (() -> Void)?

    private var draft: AnnotationObject?
    private var selectedID: UUID?
    private var dragOrigin: CGPoint?
    private var draggingHandle: AnnotationObject.Handle.Kind?
    private var didCheckpointThisDrag = false

    override var isFlipped: Bool { false }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.cgContext.setShouldAntialias(true)

        backdrop?.draw(in: bounds, from: .zero, operation: .sourceOver, fraction: 1)

        for object in document.objects { object.draw() }
        draft?.draw()

        if tool == .select,
           let id = selectedID,
           let object = document.objects.first(where: { $0.id == id }) {
            drawSelection(for: object)
        }
    }

    private func drawSelection(for object: AnnotationObject) {
        let outline = NSBezierPath(rect: object.bounds)
        outline.lineWidth = 1
        outline.setLineDash([4, 3], count: 2, phase: 0)
        NSColor.controlAccentColor.setStroke()
        outline.stroke()

        for handle in object.handles {
            let rect = CGRect(x: handle.point.x - 4.5, y: handle.point.y - 4.5, width: 9, height: 9)
            let dot = NSBezierPath(ovalIn: rect)
            NSColor.white.setFill()
            dot.fill()
            NSColor.controlAccentColor.setStroke()
            dot.lineWidth = 1.5
            dot.stroke()
        }
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        dragOrigin = point
        didCheckpointThisDrag = false

        switch tool {
        case .eraser:
            erase(at: point)

        case .select:
            // A handle grab has to win over a body hit, or a small shape can
            // never be resized — its handles sit inside its own bounds.
            if let id = selectedID,
               let object = document.objects.first(where: { $0.id == id }),
               let handle = object.handles.first(where: { hypot($0.point.x - point.x, $0.point.y - point.y) <= 8 }) {
                draggingHandle = handle.kind
                return
            }
            selectedID = document.object(at: point)?.id
            draggingHandle = nil
            needsDisplay = true

        case .text:
            break  // committed on mouseUp, where we know it was a click not a drag

        case .pen, .highlighter:
            draft = AnnotationObject(shape: .freehand([point]), style: penStyle())
            needsDisplay = true

        case .rectangle:
            draft = AnnotationObject(shape: .rectangle(CGRect(origin: point, size: .zero)), style: style)
        case .ellipse:
            draft = AnnotationObject(shape: .ellipse(CGRect(origin: point, size: .zero)), style: style)
        case .arrow:
            draft = AnnotationObject(shape: .arrow(from: point, to: point), style: style)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        switch tool {
        case .eraser:
            erase(at: point)

        case .select:
            guard let origin = dragOrigin, let id = selectedID,
                  var object = document.objects.first(where: { $0.id == id }) else { return }
            if !didCheckpointThisDrag {
                document.checkpoint()
                didCheckpointThisDrag = true
            }
            if let handle = draggingHandle {
                object.drag(handle: handle, to: point)
            } else {
                object.move(by: CGSize(width: point.x - origin.x, height: point.y - origin.y))
                dragOrigin = point
            }
            document.replace(object)
            needsDisplay = true

        case .text:
            break

        case .pen, .highlighter:
            guard case .freehand(var points)? = draft?.shape else { return }
            points.append(point)
            draft?.shape = .freehand(points)
            needsDisplay = true

        case .rectangle, .ellipse:
            guard let origin = dragOrigin else { return }
            let rect = CGRect(
                x: min(origin.x, point.x), y: min(origin.y, point.y),
                width: abs(point.x - origin.x), height: abs(point.y - origin.y)
            )
            draft?.shape = tool == .rectangle ? .rectangle(rect) : .ellipse(rect)
            needsDisplay = true

        case .arrow:
            guard let origin = dragOrigin else { return }
            draft?.shape = .arrow(from: origin, to: point)
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            dragOrigin = nil
            draggingHandle = nil
            didCheckpointThisDrag = false
        }

        if tool == .text {
            let point = convert(event.locationInWindow, from: nil)
            beginTextEntry(at: point)
            return
        }

        guard let finished = draft else {
            if tool == .eraser || tool == .select { onChange?() }
            return
        }
        draft = nil

        // Discard accidental taps from drawing tools: a zero-size rectangle or
        // a one-pixel arrow is a misclick, not a mark.
        if isDegenerate(finished) {
            needsDisplay = true
            return
        }

        document.checkpoint()
        document.append(finished)
        needsDisplay = true
        onChange?()
    }

    private func isDegenerate(_ object: AnnotationObject) -> Bool {
        switch object.shape {
        case .freehand(let points):
            return points.isEmpty
        case .rectangle(let rect), .ellipse(let rect):
            return rect.width < 3 && rect.height < 3
        case .arrow(let from, let to):
            return hypot(to.x - from.x, to.y - from.y) < 6
        case .text(let string, _, _):
            return string.isEmpty
        }
    }

    private func penStyle() -> AnnotationStyle {
        var penStyle = style
        penStyle.isHighlighter = tool == .highlighter
        if penStyle.isHighlighter { penStyle.lineWidth = max(style.lineWidth * 3, 14) }
        return penStyle
    }

    private func erase(at point: CGPoint) {
        guard let target = document.object(at: point) else { return }
        if !didCheckpointThisDrag {
            document.checkpoint()
            didCheckpointThisDrag = true
        }
        document.remove(id: target.id)
        needsDisplay = true
    }

    // MARK: - Text

    private func beginTextEntry(at point: CGPoint) {
        let field = NSTextField(frame: NSRect(x: point.x, y: point.y - 12, width: 220, height: 24))
        field.font = .systemFont(ofSize: 18, weight: .medium)
        field.textColor = style.color
        field.backgroundColor = .clear
        field.isBordered = false
        field.focusRingType = .none
        field.placeholderString = "输入文字"
        field.target = self
        field.action = #selector(commitText(_:))
        addSubview(field)
        window?.makeFirstResponder(field)
    }

    @objc private func commitText(_ sender: NSTextField) {
        let text = sender.stringValue
        let origin = CGPoint(x: sender.frame.minX, y: sender.frame.minY)
        sender.removeFromSuperview()
        guard !text.isEmpty else { return }

        document.checkpoint()
        document.append(AnnotationObject(
            shape: .text(text, origin: origin, fontSize: 18),
            style: style
        ))
        needsDisplay = true
        onChange?()
    }

    // MARK: - Commands

    func undo() { document.undo(); selectedID = nil; needsDisplay = true; onChange?() }
    func redo() { document.redo(); selectedID = nil; needsDisplay = true; onChange?() }
    func clear() { document.clear(); selectedID = nil; needsDisplay = true; onChange?() }

    func deleteSelection() {
        guard let id = selectedID else { return }
        document.checkpoint()
        document.remove(id: id)
        selectedID = nil
        needsDisplay = true
        onChange?()
    }

    override func keyDown(with event: NSEvent) {
        // 51 = delete, 117 = forward delete
        if event.keyCode == 51 || event.keyCode == 117, selectedID != nil {
            deleteSelection()
            return
        }
        super.keyDown(with: event)
    }

    private func updateCursor() {
        switch tool {
        case .select: NSCursor.arrow.set()
        case .eraser: NSCursor.disappearingItem.set()
        case .text:   NSCursor.iBeam.set()
        default:      NSCursor.crosshair.set()
        }
    }

    override func resetCursorRects() {
        discardCursorRects()
        let cursor: NSCursor
        switch tool {
        case .select: cursor = .arrow
        case .eraser: cursor = .disappearingItem
        case .text:   cursor = .iBeam
        default:      cursor = .crosshair
        }
        addCursorRect(bounds, cursor: cursor)
    }

    // MARK: - Export

    /// Flatten backdrop + annotations into one image, for saving or copying.
    func flattened() -> NSImage? {
        guard let backdrop else { return nil }
        let pixelSize = backdrop.representations.first.map {
            CGSize(width: $0.pixelsWide, height: $0.pixelsHigh)
        } ?? backdrop.size

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(pixelSize.width), pixelsHigh: Int(pixelSize.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = pixelSize

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

        let target = CGRect(origin: .zero, size: pixelSize)
        backdrop.draw(in: target, from: .zero, operation: .copy, fraction: 1)

        // Objects live in view coordinates; scale them onto the pixel grid so
        // the export matches what the user drew rather than a shrunken copy.
        let scaleX = pixelSize.width / max(bounds.width, 1)
        let scaleY = pixelSize.height / max(bounds.height, 1)
        let transform = NSAffineTransform()
        transform.scaleX(by: scaleX, yBy: scaleY)
        transform.concat()

        for object in document.objects { object.draw() }

        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: pixelSize)
        image.addRepresentation(rep)
        return image
    }
}
