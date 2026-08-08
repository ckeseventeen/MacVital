import SwiftUI
import AppKit

struct WhiteboardPage: View {
    @StateObject private var model = WhiteboardViewModel()

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                PageHeader(
                    title: "白板",
                    subtitle: "\(model.boards.count) 块白板 · 可导入图片、导出 PNG 或 PDF"
                ) {
                    Menu("导出") {
                        ForEach(WhiteboardViewModel.ExportFormat.allCases) { format in
                            Button(format.title) { model.export(as: format) }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }

                AnnotationToolbar(
                    tool: $model.tool,
                    colorIndex: $model.colorIndex,
                    widthIndex: $model.widthIndex,
                    canUndo: model.canUndo,
                    onUndo: { model.undo() },
                    onRedo: { model.redo() },
                    onClear: { model.clear() }
                )

                boardStrip
            }
            .padding(.horizontal, Theme.Metric.pagePaddingH)
            .padding(.top, Theme.Metric.pagePaddingV)
            .padding(.bottom, 16)

            WhiteboardCanvas(model: model)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.tile, style: .continuous)
                        .strokeBorder(Theme.separator, lineWidth: 1)
                )
                .padding(.horizontal, Theme.Metric.pagePaddingH)
                .padding(.bottom, Theme.Metric.pagePaddingV)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .alert(
            "白板出错",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("好") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var boardStrip: some View {
        HStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(model.boards.enumerated()), id: \.element.id) { index, board in
                        Button { model.select(index) } label: {
                            HStack(spacing: 6) {
                                if board.image != nil {
                                    Image(systemName: "photo")
                                        .font(.system(size: 11))
                                }
                                Text(board.name)
                                    .font(.system(size: 13, weight: index == model.currentIndex ? .medium : .regular))
                            }
                            .foregroundStyle(index == model.currentIndex ? Color.white : Theme.label)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(
                                index == model.currentIndex ? Theme.accent : Theme.well,
                                in: RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 1)
            }

            Divider().frame(height: 20)

            Button { model.addBoard() } label: {
                Image(systemName: "plus").frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .help("新建白板")

            Button { model.deleteCurrentBoard() } label: {
                Image(systemName: "trash").frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .help(model.boards.count > 1 ? "删除当前白板" : "清空当前白板")

            Button { model.importImage() } label: {
                Image(systemName: "photo.badge.plus").frame(width: 26, height: 26)
            }
            .buttonStyle(.plain)
            .help("导入图片作为底图")

            if model.current.image != nil {
                Button { model.removeImage() } label: {
                    Image(systemName: "photo.badge.minus").frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .help("移除底图")
            }
        }
    }
}

/// Bridges the shared annotation canvas into the whiteboard page.
private struct WhiteboardCanvas: NSViewRepresentable {
    @ObservedObject var model: WhiteboardViewModel

    func makeNSView(context: Context) -> AnnotationCanvasView {
        let canvas = AnnotationCanvasView()
        canvas.tool = model.tool
        canvas.style = model.style
        model.attach(canvas)
        return canvas
    }

    func updateNSView(_ canvas: AnnotationCanvasView, context: Context) {
        canvas.tool = model.tool
        canvas.style = model.style
        canvas.window?.invalidateCursorRects(for: canvas)
    }
}
