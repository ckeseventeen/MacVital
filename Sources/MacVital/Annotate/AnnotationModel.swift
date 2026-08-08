import AppKit

/// What the user is currently doing on a canvas.
enum AnnotationTool: String, CaseIterable, Identifiable {
    case select
    case pen
    case highlighter
    case rectangle
    case ellipse
    case arrow
    case text
    case eraser

    var id: String { rawValue }

    var title: String {
        switch self {
        case .select: return "选择"
        case .pen: return "画笔"
        case .highlighter: return "荧光笔"
        case .rectangle: return "矩形"
        case .ellipse: return "椭圆"
        case .arrow: return "箭头"
        case .text: return "文字"
        case .eraser: return "橡皮擦"
        }
    }

    var symbolName: String {
        switch self {
        case .select: return "cursorarrow"
        case .pen: return "pencil.tip"
        case .highlighter: return "highlighter"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .arrow: return "arrow.up.right"
        case .text: return "textformat"
        case .eraser: return "eraser"
        }
    }

    /// Tools that create a new object by dragging.
    var isDrawing: Bool {
        switch self {
        case .select, .eraser, .text: return false
        case .pen, .highlighter, .rectangle, .ellipse, .arrow: return true
        }
    }
}

struct AnnotationStyle: Equatable {
    var color: NSColor
    var lineWidth: CGFloat
    var isHighlighter: Bool = false
    /// Set for shapes the user chose to fill rather than outline.
    var isFilled: Bool = false
}

/// The geometry half of an object. Kept separate from style so a resize never
/// has to know about colour and a recolour never has to know about geometry.
enum AnnotationShape: Equatable {
    case freehand([CGPoint])
    case rectangle(CGRect)
    case ellipse(CGRect)
    case arrow(from: CGPoint, to: CGPoint)
    case text(String, origin: CGPoint, fontSize: CGFloat)
}

/// One editable mark on the canvas.
///
/// This type is the whole reason the annotation layer was rewritten: the first
/// version appended immutable stroke values to an array, which made undo the
/// only possible edit. Selective erasing, moving a rectangle, dragging an arrow
/// endpoint — all of them need marks to be addressable objects with identity,
/// bounds and hit testing, and none of them can be bolted onto a flat list of
/// point arrays.
struct AnnotationObject: Identifiable, Equatable {
    let id: UUID
    var shape: AnnotationShape
    var style: AnnotationStyle

    init(id: UUID = UUID(), shape: AnnotationShape, style: AnnotationStyle) {
        self.id = id
        self.shape = shape
        self.style = style
    }

    // MARK: - Geometry

    var bounds: CGRect {
        switch shape {
        case .freehand(let points):
            guard let first = points.first else { return .zero }
            return points.dropFirst().reduce(CGRect(origin: first, size: .zero)) {
                $0.union(CGRect(origin: $1, size: .zero))
            }.insetBy(dx: -style.lineWidth, dy: -style.lineWidth)
        case .rectangle(let rect), .ellipse(let rect):
            return rect.insetBy(dx: -style.lineWidth, dy: -style.lineWidth)
        case .arrow(let from, let to):
            return CGRect(
                x: min(from.x, to.x), y: min(from.y, to.y),
                width: abs(to.x - from.x), height: abs(to.y - from.y)
            ).insetBy(dx: -style.lineWidth * 3, dy: -style.lineWidth * 3)
        case .text(let string, let origin, let fontSize):
            let size = (string as NSString).size(withAttributes: [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .medium)
            ])
            return CGRect(origin: origin, size: size).insetBy(dx: -4, dy: -4)
        }
    }

    /// The drawable path. Arrows build their own head so the geometry travels
    /// with the object and a resize regenerates it automatically.
    func path() -> NSBezierPath {
        let path = NSBezierPath()
        path.lineWidth = style.lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round

        switch shape {
        case .freehand(let points):
            guard let first = points.first else { return path }
            if points.count == 1 {
                let radius = style.lineWidth / 2
                path.appendOval(in: CGRect(x: first.x - radius, y: first.y - radius,
                                           width: style.lineWidth, height: style.lineWidth))
                return path
            }
            // Midpoint smoothing — raw mouse samples are polygonal at speed.
            path.move(to: first)
            for index in 1..<points.count - 1 {
                let current = points[index]
                let next = points[index + 1]
                let mid = CGPoint(x: (current.x + next.x) / 2, y: (current.y + next.y) / 2)
                path.curve(to: mid, controlPoint1: current, controlPoint2: current)
            }
            path.line(to: points[points.count - 1])

        case .rectangle(let rect):
            path.appendRect(rect.standardized)

        case .ellipse(let rect):
            path.appendOval(in: rect.standardized)

        case .arrow(let from, let to):
            let head = max(style.lineWidth * 3.2, 12)
            let angle = atan2(to.y - from.y, to.x - from.x)
            // Stop the shaft short of the tip so the head reads as solid rather
            // than as a line poking through a triangle.
            let shaftEnd = CGPoint(
                x: to.x - cos(angle) * head * 0.62,
                y: to.y - sin(angle) * head * 0.62
            )
            path.move(to: from)
            path.line(to: shaftEnd)

            let spread = CGFloat.pi / 7
            path.move(to: to)
            path.line(to: CGPoint(x: to.x - cos(angle - spread) * head,
                                  y: to.y - sin(angle - spread) * head))
            path.line(to: CGPoint(x: to.x - cos(angle + spread) * head,
                                  y: to.y - sin(angle + spread) * head))
            path.close()

        case .text:
            break  // drawn as an attributed string, not a path
        }
        return path
    }

    /// Hit testing goes through the *stroked outline* rather than the raw path.
    /// Testing a thin line for containment never succeeds; widening it to a
    /// finger-friendly band and testing that does, and it works identically for
    /// freehand, shapes and arrows without a special case per kind.
    func hitTest(_ point: CGPoint, tolerance: CGFloat = 9) -> Bool {
        if case .text = shape { return bounds.contains(point) }

        if style.isFilled, case .rectangle(let rect) = shape { return rect.standardized.contains(point) }
        if style.isFilled, case .ellipse(let rect) = shape {
            return NSBezierPath(ovalIn: rect.standardized).contains(point)
        }

        let width = max(style.lineWidth, tolerance)
        let outline = path().cgPath.copy(
            strokingWithWidth: width,
            lineCap: .round,
            lineJoin: .round,
            miterLimit: 10
        )
        if outline.contains(point) { return true }
        // Arrow heads are closed and filled, so also accept containment.
        if case .arrow = shape { return path().cgPath.contains(point) }
        return false
    }

    // MARK: - Editing

    mutating func move(by delta: CGSize) {
        switch shape {
        case .freehand(let points):
            shape = .freehand(points.map { CGPoint(x: $0.x + delta.width, y: $0.y + delta.height) })
        case .rectangle(let rect):
            shape = .rectangle(rect.offsetBy(dx: delta.width, dy: delta.height))
        case .ellipse(let rect):
            shape = .ellipse(rect.offsetBy(dx: delta.width, dy: delta.height))
        case .arrow(let from, let to):
            shape = .arrow(
                from: CGPoint(x: from.x + delta.width, y: from.y + delta.height),
                to: CGPoint(x: to.x + delta.width, y: to.y + delta.height)
            )
        case .text(let string, let origin, let size):
            shape = .text(string, origin: CGPoint(x: origin.x + delta.width, y: origin.y + delta.height), fontSize: size)
        }
    }

    /// Handles for the selection UI. Rectangles and ellipses get four corners;
    /// an arrow gets its two ends; freehand and text get none — resampling a
    /// hand-drawn stroke under a scale gizmo looks wrong and nobody asks for it.
    var handles: [Handle] {
        switch shape {
        case .rectangle(let rect), .ellipse(let rect):
            let r = rect.standardized
            return [
                Handle(kind: .bottomLeft, point: CGPoint(x: r.minX, y: r.minY)),
                Handle(kind: .bottomRight, point: CGPoint(x: r.maxX, y: r.minY)),
                Handle(kind: .topLeft, point: CGPoint(x: r.minX, y: r.maxY)),
                Handle(kind: .topRight, point: CGPoint(x: r.maxX, y: r.maxY)),
            ]
        case .arrow(let from, let to):
            return [Handle(kind: .start, point: from), Handle(kind: .end, point: to)]
        case .freehand, .text:
            return []
        }
    }

    struct Handle: Equatable {
        enum Kind: Equatable {
            case topLeft, topRight, bottomLeft, bottomRight
            case start, end
        }
        var kind: Kind
        var point: CGPoint
    }

    mutating func drag(handle kind: Handle.Kind, to point: CGPoint) {
        switch shape {
        case .rectangle(let rect), .ellipse(let rect):
            let r = rect.standardized
            var updated = r
            switch kind {
            case .topLeft:      updated = CGRect(x: point.x, y: r.minY, width: r.maxX - point.x, height: point.y - r.minY)
            case .topRight:     updated = CGRect(x: r.minX, y: r.minY, width: point.x - r.minX, height: point.y - r.minY)
            case .bottomLeft:   updated = CGRect(x: point.x, y: point.y, width: r.maxX - point.x, height: r.maxY - point.y)
            case .bottomRight:  updated = CGRect(x: r.minX, y: point.y, width: point.x - r.minX, height: r.maxY - point.y)
            case .start, .end:  break
            }
            if case .rectangle = shape { shape = .rectangle(updated) } else { shape = .ellipse(updated) }
        case .arrow(let from, let to):
            shape = kind == .start ? .arrow(from: point, to: to) : .arrow(from: from, to: point)
        case .freehand, .text:
            break
        }
    }

    // MARK: - Drawing

    func draw() {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }

        if case .text(let string, let origin, let fontSize) = shape {
            (string as NSString).draw(at: origin, withAttributes: [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
                .foregroundColor: style.color,
            ])
            return
        }

        let paint: NSColor
        if style.isHighlighter {
            // Multiply keeps whatever is underneath readable through the mark,
            // which is the entire point of a highlighter.
            NSGraphicsContext.current?.compositingOperation = .multiply
            paint = style.color.withAlphaComponent(0.38)
        } else {
            paint = style.color
        }

        paint.setStroke()
        paint.setFill()

        let path = self.path()
        switch shape {
        case .freehand(let points) where points.count == 1:
            path.fill()
        case .arrow:
            path.stroke()
            path.fill()
        case .rectangle, .ellipse:
            if style.isFilled { path.fill() } else { path.stroke() }
        default:
            path.stroke()
        }
    }
}

extension NSBezierPath {
    /// AppKit gained `cgPath` late and the shim is still the reliable route on
    /// every OS this app supports.
    var cgPath: CGPath {
        let path = CGMutablePath()
        var points = [NSPoint](repeating: .zero, count: 3)
        for index in 0..<elementCount {
            switch element(at: index, associatedPoints: &points) {
            case .moveTo:
                path.move(to: points[0])
            case .lineTo:
                path.addLine(to: points[0])
            case .curveTo, .cubicCurveTo:
                path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .quadraticCurveTo:
                path.addQuadCurve(to: points[1], control: points[0])
            case .closePath:
                path.closeSubpath()
            @unknown default:
                break
            }
        }
        return path
    }
}
