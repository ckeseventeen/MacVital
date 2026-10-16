import Foundation

/// The order edits happened in across several canvases — one per display
/// under the screen pen — so ⌘Z takes back the last thing drawn, wherever it
/// was drawn, and only that.
///
/// Each canvas keeps its own snapshot history; this keeps which canvas each
/// step belongs to. It reads `AnnotationDocument.editCount` rather than being
/// told about edits, so nothing on the drawing path has to know it exists.
struct CanvasUndoOrder<Key: Hashable> {
    private var undoGroups: [[Key]] = []
    private var redoGroups: [[Key]] = []
    private var seenEdits: [Key: Int] = [:]

    /// Report canvases' edit counts after a change. Anything new since the
    /// last report is new work, and new work ends the redo future. Several
    /// canvases changing in one report — 清空 — are one step.
    mutating func record(_ editCounts: [Key: Int]) {
        var together: [Key] = []
        var earlier: [[Key]] = []
        for (key, count) in editCounts {
            let new = count - (seenEdits[key] ?? 0)
            seenEdits[key] = count
            guard new > 0 else { continue }
            together.append(key)
            earlier += Array(repeating: [key], count: new - 1)
        }
        guard !together.isEmpty else { return }
        undoGroups += earlier
        undoGroups.append(together)
        redoGroups.removeAll()
    }

    /// The canvases to undo for one ⌘Z, or nil when there is nothing left.
    mutating func takeUndo() -> [Key]? {
        guard let group = undoGroups.popLast() else { return nil }
        redoGroups.append(group)
        return group
    }

    mutating func takeRedo() -> [Key]? {
        guard let group = redoGroups.popLast() else { return nil }
        undoGroups.append(group)
        return group
    }

    /// A display went away, and its canvas with it.
    mutating func forget(_ key: Key) {
        undoGroups = undoGroups.map { $0.filter { $0 != key } }.filter { !$0.isEmpty }
        redoGroups = redoGroups.map { $0.filter { $0 != key } }.filter { !$0.isEmpty }
        seenEdits[key] = nil
    }

    mutating func reset() {
        self = CanvasUndoOrder()
    }
}
