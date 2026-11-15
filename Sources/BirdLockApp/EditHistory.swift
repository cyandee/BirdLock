import AppKit
import BirdLockCore

/// Session-only snapshots share the analysis arrays until an edit changes them.
@MainActor
struct EditHistory {
    struct Snapshot {
        var analysis: SequenceAnalysis
        var profile: SubjectProfile
        var audio: AudioSettings
        var watermark: WatermarkSettings
        var segments: [BurstSegment]
        var order: [Int]
    }

    private var previous: [Snapshot] = []
    private var next: [Snapshot] = []
    private var current: Snapshot?
    private var recordingDrag = false
    mutating func endGesture() { recordingDrag = false }

    var canUndo: Bool { !previous.isEmpty }
    var canRedo: Bool { !next.isEmpty }

    mutating func reset(to snapshot: Snapshot?) { self = EditHistory(); current = snapshot }

    mutating func record(_ snapshot: Snapshot) {
        let event = NSApp.currentEvent?.type
        let dragging = event == .leftMouseDragged || (event == .leftMouseUp && recordingDrag)
        // A mouse-down can change slider values before the first drag event.
        if let current, !dragging || !recordingDrag {
            previous.append(current)
            if previous.count > 40 { previous.removeFirst() }
        }
        current = snapshot
        recordingDrag = dragging || event == .leftMouseDown
        next.removeAll()
    }

    mutating func undo() -> Snapshot? {
        guard let current, let result = previous.popLast() else { return nil }
        next.append(current)
        self.current = result
        recordingDrag = false
        return result
    }

    mutating func redo() -> Snapshot? {
        guard let current, let result = next.popLast() else { return nil }
        previous.append(current)
        self.current = result
        recordingDrag = false
        return result
    }
}
