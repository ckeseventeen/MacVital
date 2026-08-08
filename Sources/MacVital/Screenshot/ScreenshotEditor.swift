import SwiftUI
import AppKit

/// Annotation over a captured screenshot.
///
/// The whole reason the annotation layer became an object model: this is the
/// *same* `AnnotationCanvasView` the screen overlay uses, with an image behind
/// it instead of a transparent window. Tools, hit testing, undo and the export
/// path are shared — there is no second drawing engine to keep in sync.
struct ScreenshotEditor: NSViewRepresentable {
    let image: NSImage
    let tool: AnnotationTool
    let style: AnnotationStyle
    /// Handed back so the page can copy or save the flattened result without
    /// reaching into the view hierarchy.
    let canvasRef: CanvasBox
    var onChange: () -> Void

    /// A reference cell for the canvas. `NSViewRepresentable` builds the view
    /// on demand and SwiftUI owns its lifetime; this is how the page gets a
    /// handle on it without keeping the view itself in `@State`.
    final class CanvasBox: ObservableObject {
        weak var canvas: AnnotationCanvasView?
        @Published var canUndo = false
    }

    func makeNSView(context: Context) -> AnnotationCanvasView {
        let canvas = AnnotationCanvasView()
        canvas.backdrop = image
        canvas.tool = tool
        canvas.style = style
        canvas.onChange = { [weak canvas] in
            canvasRef.canUndo = canvas?.document.canUndo ?? false
            onChange()
        }
        canvasRef.canvas = canvas
        return canvas
    }

    func updateNSView(_ canvas: AnnotationCanvasView, context: Context) {
        if canvas.backdrop !== image { canvas.backdrop = image }
        canvas.tool = tool
        canvas.style = style
        canvas.window?.invalidateCursorRects(for: canvas)
        canvas.needsDisplay = true
    }
}

/// The tool strip above the screenshot canvas. Mirrors the floating palette on
/// the screen overlay so the two surfaces do not teach different vocabularies.
struct AnnotationToolbar: View {
    @Binding var tool: AnnotationTool
    @Binding var colorIndex: Int
    @Binding var widthIndex: Int
    let canUndo: Bool
    let onUndo: () -> Void
    let onRedo: () -> Void
    let onClear: () -> Void

    private let tools: [AnnotationTool] = [.select, .pen, .highlighter, .rectangle, .ellipse, .arrow, .text, .eraser]

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 3) {
                ForEach(tools) { candidate in
                    toolButton(candidate)
                }
            }

            Divider().frame(height: 20)

            HStack(spacing: 6) {
                ForEach(Array(ScreenPenController.palette.enumerated()), id: \.offset) { index, color in
                    Button { colorIndex = index } label: {
                        Circle()
                            .fill(Color(nsColor: color))
                            .frame(width: 16, height: 16)
                            .overlay(Circle().strokeBorder(Theme.label, lineWidth: colorIndex == index ? 2 : 0))
                            .overlay(Circle().strokeBorder(Theme.separator, lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider().frame(height: 20)

            HStack(spacing: 4) {
                ForEach(Array(ScreenPenController.widths.enumerated()), id: \.offset) { index, width in
                    Button { widthIndex = index } label: {
                        Circle()
                            .fill(widthIndex == index ? Color(nsColor: ScreenPenController.palette[colorIndex]) : Theme.secondaryLabel)
                            .frame(width: width + 3, height: width + 3)
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer(minLength: 8)

            Button(action: onUndo) { Image(systemName: "arrow.uturn.backward") }
                .buttonStyle(.plain)
                .disabled(!canUndo)
                .help("撤销（⌘Z）")
            Button(action: onRedo) { Image(systemName: "arrow.uturn.forward") }
                .buttonStyle(.plain)
                .help("重做")
            Button(action: onClear) { Image(systemName: "trash") }
                .buttonStyle(.plain)
                .disabled(!canUndo)
                .help("清空标注")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .glassPanel(cornerRadius: Theme.Radius.tile)
    }

    private func toolButton(_ candidate: AnnotationTool) -> some View {
        Button { tool = candidate } label: {
            Image(systemName: candidate.symbolName)
                .font(.system(size: 14))
                .foregroundStyle(tool == candidate ? Color.white : Theme.label)
                .frame(width: 26, height: 26)
                .background(
                    tool == candidate ? Theme.accent : Color.clear,
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .help(candidate.title)
    }
}
