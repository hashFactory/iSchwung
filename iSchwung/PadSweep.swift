import SwiftUI

// Multitouch sweep layer over the 4×8 pad grid. One view owns touches across the
// whole grid, so a finger sliding from pad to pad retriggers each one it enters —
// the glissando you'd get pressing and dragging on a real Move. Per-pad SwiftUI
// gestures can't do this: each captures only the pad the touch began on.

private enum PadGeom { static let rows = 4, cols = 8; static let spacing: CGFloat = 10 }

/// Map a point in the grid's local space to a pad note, or -1 if outside. Gaps
/// between pads fold into the preceding pad so a sweep never hits a dead zone.
private func padNote(at p: CGPoint, in size: CGSize) -> Int {
    guard size.width > 0, size.height > 0,
          p.x >= 0, p.y >= 0, p.x < size.width, p.y < size.height else { return -1 }
    let s = PadGeom.spacing
    let cw = (size.width  - s * CGFloat(PadGeom.cols - 1)) / CGFloat(PadGeom.cols)
    let ch = (size.height - s * CGFloat(PadGeom.rows - 1)) / CGFloat(PadGeom.rows)
    let col = min(PadGeom.cols - 1, max(0, Int(p.x / (cw + s))))
    let row = min(PadGeom.rows - 1, max(0, Int(p.y / (ch + s))))
    return MoveMap.pad(row: row, col: col)
}

/// Note-on/off with reference counting so two fingers sharing a pad (or crossing
/// each other) don't drop a note early: on at 0→1, off at 1→0.
final class PadSweepTracker {
    private let engine: SchwungEngine
    private var count: [Int: Int] = [:]
    init(_ engine: SchwungEngine) { self.engine = engine }

    func enter(_ note: Int) {
        guard note >= 0 else { return }
        let c = (count[note] ?? 0) + 1
        count[note] = c
        if c == 1 { engine.sendNote(note, on: true); engine.padDown.insert(note) }
    }
    func leave(_ note: Int) {
        guard note >= 0, let c0 = count[note] else { return }
        if c0 <= 1 { count[note] = nil; engine.sendNote(note, on: false); engine.padDown.remove(note) }
        else { count[note] = c0 - 1 }
    }
}

#if os(iOS)
import UIKit

struct PadTouchSurface: UIViewRepresentable {
    let engine: SchwungEngine
    func makeUIView(context: Context) -> PadTouchView { PadTouchView(engine: engine) }
    func updateUIView(_ v: PadTouchView, context: Context) {}
}

final class PadTouchView: UIView {
    private let tracker: PadSweepTracker
    private var touchNote: [ObjectIdentifier: Int] = [:]

    init(engine: SchwungEngine) {
        tracker = PadSweepTracker(engine)
        super.init(frame: .zero)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            let n = padNote(at: t.location(in: self), in: bounds.size)
            touchNote[ObjectIdentifier(t)] = n
            tracker.enter(n)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            let id = ObjectIdentifier(t)
            // Walk coalesced samples so a fast swipe still triggers every pad it
            // crossed, not just the endpoints.
            for ct in event?.coalescedTouches(for: t) ?? [t] {
                let n = padNote(at: ct.location(in: self), in: bounds.size)
                let old = touchNote[id] ?? -1
                if n != old { tracker.leave(old); tracker.enter(n); touchNote[id] = n }
            }
        }
    }

    private func end(_ touches: Set<UITouch>) {
        for t in touches {
            let id = ObjectIdentifier(t)
            tracker.leave(touchNote[id] ?? -1)
            touchNote[id] = nil
        }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { end(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { end(touches) }
}
#endif

#if os(macOS)
import AppKit

struct PadTouchSurface: NSViewRepresentable {
    let engine: SchwungEngine
    func makeNSView(context: Context) -> PadTouchView { PadTouchView(engine: engine) }
    func updateNSView(_ v: PadTouchView, context: Context) {}
}

final class PadTouchView: NSView {
    private let tracker: PadSweepTracker
    private var current = -1   // single pointer on macOS

    init(engine: SchwungEngine) {
        tracker = PadSweepTracker(engine)
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("not used") }
    override var isFlipped: Bool { true }   // origin top-left, matching iOS / the grid

    private func note(_ e: NSEvent) -> Int {
        padNote(at: convert(e.locationInWindow, from: nil), in: bounds.size)
    }
    override func mouseDown(with e: NSEvent) { current = note(e); tracker.enter(current) }
    override func mouseDragged(with e: NSEvent) {
        let n = note(e)
        if n != current { tracker.leave(current); tracker.enter(n); current = n }
    }
    override func mouseUp(with e: NSEvent) { tracker.leave(current); current = -1 }
}
#endif
