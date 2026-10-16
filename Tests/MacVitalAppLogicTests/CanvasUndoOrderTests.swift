import AppKit
import XCTest

/// The screen pen draws on one canvas per display. ⌘Z used to undo on every
/// canvas at once, so one keystroke took back the latest stroke on the
/// projector and on the laptop together.
final class CanvasUndoOrderTests: XCTestCase {
    private enum Screen { case laptop, projector }

    func testUndoTakesBackOnlyTheLatestStepWhereverItWasDrawn() {
        var order = CanvasUndoOrder<Screen>()
        order.record([.laptop: 1])
        order.record([.projector: 1])

        XCTAssertEqual(order.takeUndo(), [.projector])
        XCTAssertEqual(order.takeUndo(), [.laptop])
        XCTAssertNil(order.takeUndo())
    }

    func testRedoReplaysInOrderAndNewWorkEndsIt() {
        var order = CanvasUndoOrder<Screen>()
        order.record([.laptop: 1])
        order.record([.projector: 1])
        _ = order.takeUndo()
        _ = order.takeUndo()

        XCTAssertEqual(order.takeRedo(), [.laptop])
        order.record([.projector: 2])
        XCTAssertNil(order.takeRedo(), "a new stroke ends the redo future")
        XCTAssertEqual(order.takeUndo(), [.projector])
    }

    /// Undo and redo report the same edit count back; they are not new steps.
    func testRepeatedReportOfTheSameCountIsNotAStep() {
        var order = CanvasUndoOrder<Screen>()
        order.record([.laptop: 1])
        order.record([.laptop: 1])
        XCTAssertEqual(order.takeUndo(), [.laptop])
        XCTAssertNil(order.takeUndo())
    }

    /// 清空 touches every display in one action, and comes back in one.
    func testClearingSeveralCanvasesIsOneStep() throws {
        var order = CanvasUndoOrder<Screen>()
        order.record([.laptop: 1])
        order.record([.projector: 1])
        order.record([.laptop: 2, .projector: 2])

        XCTAssertEqual(Set(try XCTUnwrap(order.takeUndo())), [.laptop, .projector])
        XCTAssertEqual(order.takeUndo(), [.projector])
    }

    func testDetachedDisplayDropsOutOfTheHistory() {
        var order = CanvasUndoOrder<Screen>()
        order.record([.laptop: 1])
        order.record([.projector: 1])
        order.forget(.projector)
        XCTAssertEqual(order.takeUndo(), [.laptop])
        XCTAssertNil(order.takeUndo())
    }

    /// Wired to real documents: the edit counter is what the pen reports.
    @MainActor
    func testDocumentEditCountAdvancesOnEditsOnly() {
        let canvas = AnnotationCanvasView()
        let mark = AnnotationObject(
            shape: .rectangle(CGRect(x: 0, y: 0, width: 10, height: 10)),
            style: AnnotationStyle(color: .red, lineWidth: 2)
        )
        canvas.document.checkpoint()
        canvas.document.append(mark)
        XCTAssertEqual(canvas.document.editCount, 1)
        canvas.undo()
        canvas.redo()
        XCTAssertEqual(canvas.document.editCount, 1)
        canvas.clear()
        XCTAssertEqual(canvas.document.editCount, 2)
    }
}

/// An annotated screenshot must come out the size the plain one does.
final class ScreenshotFlattenTests: XCTestCase {
    @MainActor
    func testFlattenedRetinaCaptureKeepsItsPointSizeAndEveryPixel() throws {
        // A 2x capture: 200 x 100 pixels presented at 100 x 50 points.
        let pixels = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 200, pixelsHigh: 100,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        pixels.size = NSSize(width: 100, height: 50)
        let capture = NSImage(size: pixels.size)
        capture.addRepresentation(pixels)

        let canvas = AnnotationCanvasView(frame: NSRect(x: 0, y: 0, width: 100, height: 50))
        canvas.backdrop = capture
        let flattened = try XCTUnwrap(canvas.flattened())

        XCTAssertEqual(flattened.size, NSSize(width: 100, height: 50))
        let rep = try XCTUnwrap(flattened.representations.first as? NSBitmapImageRep)
        XCTAssertEqual(rep.pixelsWide, 200)
        XCTAssertEqual(rep.pixelsHigh, 100)
    }
}
