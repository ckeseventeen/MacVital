import AppKit
import XCTest

final class WhiteboardTests: XCTestCase {
    @MainActor
    func testDrawingSurvivesCanvasRecreation() async {
        let model = WhiteboardViewModel()
        var canvas: AnnotationCanvasView? = AnnotationCanvasView()
        model.attach(canvas!)
        let mark = AnnotationObject(
            shape: .rectangle(CGRect(x: 10, y: 20, width: 30, height: 40)),
            style: model.style
        )
        canvas!.document.checkpoint()
        canvas!.document.append(mark)
        canvas!.onChange?()
        XCTAssertTrue(model.canUndo)
        canvas = nil
        let replacement = AnnotationCanvasView()
        model.attach(replacement)
        XCTAssertEqual(replacement.document.objects, [mark])
        XCTAssertFalse(model.canUndo, "A recreated canvas has no undo history")
    }

    @MainActor
    func testBoardSwitchAndUndoDoNotChangeOtherBoard() async {
        let model = WhiteboardViewModel()
        let canvas = AnnotationCanvasView()
        model.attach(canvas)
        let mark = AnnotationObject(
            shape: .ellipse(CGRect(x: 0, y: 0, width: 20, height: 20)), style: model.style
        )
        canvas.document.checkpoint()
        canvas.document.append(mark)
        canvas.onChange?()
        model.addBoard()
        XCTAssertTrue(canvas.document.isEmpty)
        model.undo()
        XCTAssertTrue(canvas.document.isEmpty)
        model.select(0)
        XCTAssertEqual(canvas.document.objects, [mark])
        model.clear()
        XCTAssertTrue(model.current.objects.isEmpty)
        model.undo()
        XCTAssertEqual(model.current.objects, [mark])
    }

    @MainActor
    func testDeletingLastBoardLeavesUsableCanvas() async {
        let model = WhiteboardViewModel()
        let canvas = AnnotationCanvasView()
        model.attach(canvas)
        model.deleteCurrentBoard()
        XCTAssertEqual(model.boards.count, 1)
        XCTAssertEqual(model.currentIndex, 0)
        XCTAssertTrue(canvas.document.isEmpty)
        model.addBoard()
        model.deleteCurrentBoard()
        XCTAssertEqual(model.currentIndex, 0)
    }
}
