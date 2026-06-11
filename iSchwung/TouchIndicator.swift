#if !os(macOS)
import SwiftUI
import UIKit

/// Full-screen, non-interactive overlay that draws a faint white circle under
/// every active touch — so screen recordings show what's being pressed. A
/// passive gesture recognizer on the window observes touches without consuming
/// them; circles are CAShapeLayers (no SwiftUI invalidation).
struct TouchIndicator: UIViewRepresentable {
    func makeUIView(context: Context) -> TouchCanvas { TouchCanvas() }
    func updateUIView(_ v: TouchCanvas, context: Context) {}
}

final class TouchCanvas: UIView {
    private var pool: [CAShapeLayer] = []
    private let radius: CGFloat = 28
    private weak var tracker: TouchTracker?

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false        // never eat touches
        backgroundColor = .clear
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard let window, tracker == nil else { return }
        let t = TouchTracker()
        t.canvas = self
        window.addGestureRecognizer(t)
        tracker = t
    }

    func render(_ points: [CGPoint]) {
        while pool.count < points.count {
            let l = CAShapeLayer()
            l.fillColor = UIColor.white.withAlphaComponent(0.16).cgColor
            l.strokeColor = UIColor.white.withAlphaComponent(0.45).cgColor
            l.lineWidth = 1.5
            layer.addSublayer(l)
            pool.append(l)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, l) in pool.enumerated() {
            if i < points.count {
                let p = points[i]
                l.path = UIBezierPath(ovalIn: CGRect(x: p.x - radius, y: p.y - radius,
                                                     width: radius * 2, height: radius * 2)).cgPath
                l.isHidden = false
            } else {
                l.isHidden = true
            }
        }
        CATransaction.commit()
    }
}

/// Observes all touches on the window passively (never recognizes, never
/// cancels others) and reports their positions in the canvas's coordinate space.
final class TouchTracker: UIGestureRecognizer, UIGestureRecognizerDelegate {
    weak var canvas: TouchCanvas?

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }
    convenience init() { self.init(target: nil, action: nil) }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) { report(event) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) { report(event) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { report(event) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { report(event) }

    private func report(_ event: UIEvent) {
        guard let canvas else { return }
        let pts = (event.allTouches ?? []).filter {
            $0.phase != .ended && $0.phase != .cancelled
        }.map { $0.location(in: canvas) }
        canvas.render(pts)
    }

    // Observe alongside the controls' own gestures rather than blocking them.
    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}
#endif
