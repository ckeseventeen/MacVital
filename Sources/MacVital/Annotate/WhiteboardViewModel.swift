import AppKit
import UniformTypeIdentifiers

/// Multi-board whiteboard state.
///
/// A board is annotation objects plus an optional imported image. Drawing is
/// the same `AnnotationCanvasView` used by the screen overlay and the
/// screenshot editor — the whiteboard is that canvas over a blank page.
@MainActor
final class WhiteboardViewModel: ObservableObject {
    struct Board: Identifiable {
        let id = UUID()
        var name: String
        var objects: [AnnotationObject] = []
        var image: NSImage?
    }

    @Published private(set) var boards: [Board] = [Board(name: "白板 1")]
    @Published private(set) var currentIndex = 0
    @Published var tool: AnnotationTool = .pen
    @Published var colorIndex = 6   // near-black reads best on white
    @Published var widthIndex = 1
    @Published var errorMessage: String?
    @Published private(set) var canUndo = false

    weak var canvas: AnnotationCanvasView?

    var current: Board { boards[currentIndex] }

    var style: AnnotationStyle {
        AnnotationStyle(
            color: ScreenPenController.palette[colorIndex],
            lineWidth: ScreenPenController.widths[widthIndex]
        )
    }

    // MARK: - Boards

    func select(_ index: Int) {
        guard index != currentIndex, boards.indices.contains(index) else { return }
        commitCurrent()
        currentIndex = index
        loadCurrentIntoCanvas()
    }

    func addBoard() {
        commitCurrent()
        boards.append(Board(name: "白板 \(boards.count + 1)"))
        currentIndex = boards.count - 1
        loadCurrentIntoCanvas()
    }

    func deleteCurrentBoard() {
        guard boards.count > 1 else {
            // Never leave the user with no canvas; clearing is the sane
            // interpretation of "delete" when only one board is left.
            boards[0] = Board(name: boards[0].name)
            loadCurrentIntoCanvas()
            return
        }
        boards.remove(at: currentIndex)
        currentIndex = min(currentIndex, boards.count - 1)
        loadCurrentIntoCanvas()
    }

    /// Pull whatever is on the canvas back into the board before switching
    /// away, or the drawing is lost the moment the user clicks another tab.
    private func commitCurrent() {
        guard let canvas, boards.indices.contains(currentIndex) else { return }
        boards[currentIndex].objects = canvas.document.objects
    }

    private func loadCurrentIntoCanvas() {
        guard let canvas else { return }
        canvas.document.load(current.objects)
        canvas.backdrop = current.image
        canvas.needsDisplay = true
        refreshUndoState()
    }

    func attach(_ canvas: AnnotationCanvasView) {
        self.canvas = canvas
        canvas.backdrop = current.image
        canvas.document.load(current.objects)
        canvas.onChange = { [weak self] in
            Task { @MainActor in self?.refreshUndoState() }
        }
    }

    /// Strictly `canUndo`, matching `ScreenPenController`.
    ///
    /// This read `canUndo || !isEmpty`, which is the exact bug the pen fixed
    /// and this copy kept: a board loaded from another tab has objects but an
    /// empty undo stack, so the button lit up and did nothing when pressed —
    /// indistinguishable from a missed click.
    private func refreshUndoState() {
        canUndo = canvas?.document.canUndo ?? false
    }

    // MARK: - Commands

    func undo() { canvas?.undo() }
    func redo() { canvas?.redo() }
    func clear() { canvas?.clear() }

    // MARK: - Import / export

    func importImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "选择要导入到当前白板的图片"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let image = NSImage(contentsOf: url) else {
            errorMessage = "无法读取这个图片文件。"
            return
        }
        boards[currentIndex].image = image
        canvas?.backdrop = image
        canvas?.needsDisplay = true
    }

    func removeImage() {
        boards[currentIndex].image = nil
        canvas?.backdrop = nil
        canvas?.needsDisplay = true
    }

    /// Export the *current* board. Multi-board export goes to PDF, one page
    /// each, which is why the format choice matters here.
    func export(as format: ExportFormat) {
        commitCurrent()

        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = format == .pdf ? "白板.pdf" : "\(current.name).png"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            switch format {
            case .png:
                guard let data = renderPNG(board: current) else {
                    errorMessage = "无法生成图片。"
                    return
                }
                try data.write(to: url, options: .atomic)
            case .pdf:
                guard let data = renderPDF(boards: boards) else {
                    errorMessage = "无法生成 PDF。"
                    return
                }
                try data.write(to: url, options: .atomic)
            }
        } catch {
            errorMessage = "导出失败：\(error.localizedDescription)"
        }
    }

    enum ExportFormat: String, CaseIterable, Identifiable {
        case png
        case pdf
        var id: String { rawValue }
        var title: String { self == .png ? "PNG（当前白板）" : "PDF（全部白板）" }
        var contentType: UTType { self == .png ? .png : .pdf }
    }

    /// A fixed 1600×1000 page. Exporting at the window's current size would
    /// make the output depend on how the user happened to resize the app.
    private static let pageSize = CGSize(width: 1600, height: 1000)

    /// The largest centred rect of `size`'s aspect ratio that fits in `bounds`.
    private static func fit(_ size: CGSize, into bounds: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(
            x: bounds.midX - fitted.width / 2,
            y: bounds.midY - fitted.height / 2,
            width: fitted.width,
            height: fitted.height
        )
    }

    private func renderPNG(board: Board) -> Data? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(Self.pageSize.width), pixelsHigh: Int(Self.pageSize.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = Self.pageSize

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        drawBoard(board, in: CGRect(origin: .zero, size: Self.pageSize))
        NSGraphicsContext.restoreGraphicsState()

        return rep.representation(using: .png, properties: [:])
    }

    private func renderPDF(boards: [Board]) -> Data? {
        let data = NSMutableData()
        var mediaBox = CGRect(origin: .zero, size: Self.pageSize)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else { return nil }

        for board in boards {
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            drawBoard(board, in: mediaBox)
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    /// Objects were laid out in view coordinates; scale them onto the page so
    /// the export matches what was drawn rather than a corner of it.
    private func drawBoard(_ board: Board, in rect: CGRect) {
        NSColor.white.setFill()
        rect.fill()
        // Aspect-fit, centred. Drawing into `rect` stretched every imported
        // image to the page, so the export did not match what was on screen.
        if let image = board.image {
            image.draw(in: Self.fit(image.size, into: rect), from: .zero, operation: .sourceOver, fraction: 1)
        }

        let canvasSize = canvas?.bounds.size ?? rect.size
        let scale = min(rect.width / max(canvasSize.width, 1), rect.height / max(canvasSize.height, 1))

        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.scaleX(by: scale, yBy: scale)
        transform.concat()
        for object in board.objects { object.draw() }
        NSGraphicsContext.restoreGraphicsState()
    }
}
