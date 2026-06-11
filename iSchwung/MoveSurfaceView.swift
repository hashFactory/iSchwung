import SwiftUI

// MARK: - Move control MIDI map (src/shared/constants.mjs)

enum MoveMap {
    static let jogClick = 3, jogWheel = 14
    static let shift = 49, menu = 50, back = 51, capture = 52
    static let down = 54, up = 55, undo = 56, loop = 58, copy = 60
    static let left = 62, right = 63
    static let knobs = Array(71...78)          // relative encoders
    static let master = 79
    static let play = 85, rec = 86, mute = 88
    static let sample = 118, delete = 119
    static let tracks = [43, 42, 41, 40]       // top → bottom (reversed on purpose)
    static let knobTouch = Array(0...7), masterTouch = 8, jogTouch = 9
    /// Pad note for visual row (0 = top) and column: bottom-left is 68.
    static func pad(row: Int, col: Int) -> Int { 68 + (3 - row) * 8 + col }
    static let steps = Array(16...31)
}

// MARK: - Theme

// OLED-friendly: true-black body (pixels off) with high-contrast outlines
// instead of mid-gray fills.
enum Theme {
    static let body = Color.black
    static let well = Color.black
    static let control = Color(red: 0.10, green: 0.10, blue: 0.11)
    static let controlBorder = Color.white.opacity(0.22)
    static let label = Color.white.opacity(0.85)
    static let padOff = Color(red: 0.13, green: 0.13, blue: 0.14)
    /// Default track identity colors (Move firmware drives the real LEDs
    /// on-device; standing in for it here). Track 1...4.
    static let trackColors: [Color] = [
        Color(red: 0.00, green: 0.45, blue: 0.99),   // azure
        Color(red: 0.39, green: 0.29, blue: 0.85),   // violet
        Color(red: 0.95, green: 0.23, blue: 0.05),   // orange-red
        Color(red: 0.10, green: 1.00, blue: 0.19),   // neon green
    ]
}

// MARK: - Root surface

struct MoveSurfaceView: View {
    @ObservedObject var engine: SchwungEngine

    var body: some View {
        #if os(macOS)
        surface
        #else
        // Fixed-layout surface scaled to whatever screen we get (best in landscape)
        GeometryReader { geo in
            surface
                .scaleEffect(min(geo.size.width / 1180, geo.size.height / 600))
                .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(Theme.well)
        .ignoresSafeArea()
        .statusBarHidden()
        #endif
    }

    private var surface: some View {
        VStack(spacing: 14) {
            topRow
            middleRow
            bottomRow
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: 1180, height: 600)
        .background(Theme.body)
        .overlay(alignment: .bottomLeading) {
            Text(engine.status)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Theme.label.opacity(0.5))
                .padding(.leading, 26).padding(.bottom, 8)
        }
    }

    private var topRow: some View {
        HStack(alignment: .center, spacing: 14) {
            DisplayView(image: engine.displayImage)
            Spacer(minLength: 8)
            ForEach(0..<8, id: \.self) { i in
                KnobColumn(name: engine.knobNames[i], value: engine.knobValues[i]) {
                    EncoderKnob(size: 68,
                                onDelta: { engine.sendEncoder(MoveMap.knobs[i], delta: $0) },
                                onHover: { engine.encoderHover(cc: MoveMap.knobs[i],
                                                               touchNote: MoveMap.knobTouch[i],
                                                               inside: $0) })
                }
            }
            StatusLEDs(running: engine.engineRunning, level: engine.audioLevel)
            Spacer(minLength: 8)
            KnobColumn(name: "Volume", value: "") {
                EncoderKnob(size: 80,
                            onDelta: { engine.sendEncoder(MoveMap.master, delta: $0) },
                            onHover: { engine.encoderHover(cc: MoveMap.master,
                                                           touchNote: MoveMap.masterTouch,
                                                           inside: $0) })
            }
        }
    }

    private var middleRow: some View {
        HStack(alignment: .top, spacing: 18) {
            VStack(spacing: 16) {
                JogWheel(onDelta: { engine.sendEncoder(MoveMap.jogWheel, delta: $0) },
                         onPressBegan: { engine.jogPressBegan() },
                         onPressEnded: { engine.jogPressEnded() },
                         onPressCancelled: { engine.jogPressCancelled() },
                         onHover: { engine.encoderHover(cc: MoveMap.jogWheel,
                                                        touchNote: MoveMap.jogTouch,
                                                        invertArrows: true,
                                                        inside: $0) })
                // Upside-down triangle: Back + Menu on top, gear centered below.
                VStack(spacing: 10) {
                    HStack(spacing: 22) {
                        RoundButton(symbol: "chevron.left", size: 50, led: engine.ccLEDs[MoveMap.back]) {
                            engine.tapButton(MoveMap.back)
                        }
                        RoundButton(symbol: "line.3.horizontal", size: 50, led: engine.ccLEDs[MoveMap.menu]) {
                            engine.tapButton(MoveMap.menu)
                        }
                    }
                    // Long-pressing the jog or Shift+touch-master+jog open Settings too.
                    RoundButton(symbol: "gearshape.fill", size: 50, led: nil) {
                        engine.jumpToSettings()
                    }
                }
            }
            .frame(width: 150)

            trackColumn
            padGrid
            rightButtons
        }
    }

    private var trackColumn: some View {
        VStack(spacing: 10) {
            ForEach(Array(MoveMap.tracks.enumerated()), id: \.offset) { idx, cc in
                let led = MovePalette.color(engine.ccLEDs[cc] ?? 0)
                let base = led == .clear ? Theme.trackColors[idx] : led
                TrackBar(color: base.opacity(engine.selectedSlot == idx ? 1.0 : 0.45),
                         glow: engine.selectedSlot == idx) {
                    engine.tapButton(cc)
                }
            }
        }
    }

    private var padGrid: some View {
        // Pads glow in the selected track's color when its chain is playable.
        let playable = engine.slotActive[engine.selectedSlot]
        let defaultColor = playable
            ? Theme.trackColors[engine.selectedSlot].opacity(0.32) : Color.clear
        return Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            ForEach(0..<4, id: \.self) { row in
                GridRow {
                    ForEach(0..<8, id: \.self) { col in
                        let note = MoveMap.pad(row: row, col: col)
                        let led = MovePalette.color(engine.noteLEDs[note] ?? 0)
                        PadView(color: led == .clear ? defaultColor : led,
                                pressColor: Theme.trackColors[engine.selectedSlot],
                                press: { engine.sendNote(note, on: $0) })
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var rightButtons: some View {
        Grid(horizontalSpacing: 12, verticalSpacing: 16) {
            GridRow {
                RoundButton(symbol: "viewfinder", led: engine.ccLEDs[MoveMap.capture]) {
                    engine.tapButton(MoveMap.capture)
                }
                RoundButton(symbol: "circle.fill", rgb: engine.ccLEDs[MoveMap.sample]) {
                    engine.tapButton(MoveMap.sample)
                }
            }
            GridRow {
                RoundButton(symbol: "repeat", led: engine.ccLEDs[MoveMap.loop]) {
                    engine.tapButton(MoveMap.loop)
                }
                RoundButton(text: "M", led: engine.ccLEDs[MoveMap.mute]) {
                    engine.tapButton(MoveMap.mute)
                }
            }
            GridRow {
                RoundButton(symbol: "xmark", led: engine.ccLEDs[MoveMap.delete]) {
                    engine.tapButton(MoveMap.delete)
                }
                RoundButton(symbol: "square.on.square", led: engine.ccLEDs[MoveMap.copy]) {
                    engine.tapButton(MoveMap.copy)
                }
            }
            GridRow {
                RoundButton(symbol: "arrow.uturn.backward", led: engine.ccLEDs[MoveMap.undo]) {
                    engine.tapButton(MoveMap.undo)
                }
                RoundButton(symbol: "shift.fill", led: engine.shiftHeld ? 127 : 0) {
                    engine.toggleShift()
                }
            }
        }
        .frame(width: 130)
    }

    private var bottomRow: some View {
        HStack(spacing: 18) {
            HStack(spacing: 12) {
                RoundButton(symbol: "play.fill", rgb: engine.ccLEDs[MoveMap.play]) {
                    engine.tapButton(MoveMap.play)
                }
                RoundButton(symbol: "record.circle", rgb: engine.ccLEDs[MoveMap.rec]) {
                    engine.tapButton(MoveMap.rec)
                }
            }
            .frame(width: 150, alignment: .leading)

            HStack(spacing: 8) {
                ForEach(MoveMap.steps, id: \.self) { note in
                    StepButton(rgb: engine.noteLEDs[note], white: engine.ccLEDs[note],
                               press: { engine.sendNote(note, on: $0) })
                }
            }
            .frame(maxWidth: .infinity)

            // compact d-pad cross: + / − vertical, ‹ / › horizontal
            Grid(horizontalSpacing: 5, verticalSpacing: 5) {
                GridRow {
                    Color.clear.frame(width: 30, height: 30)
                    RoundButton(symbol: "plus", small: true, led: engine.ccLEDs[MoveMap.up]) {
                        engine.tapButton(MoveMap.up)
                    }
                    Color.clear.frame(width: 30, height: 30)
                }
                GridRow {
                    RoundButton(symbol: "chevron.left", small: true, led: engine.ccLEDs[MoveMap.left]) {
                        engine.tapButton(MoveMap.left)
                    }
                    Color.clear.frame(width: 30, height: 30)
                    RoundButton(symbol: "chevron.right", small: true, led: engine.ccLEDs[MoveMap.right]) {
                        engine.tapButton(MoveMap.right)
                    }
                }
                GridRow {
                    Color.clear.frame(width: 30, height: 30)
                    RoundButton(symbol: "minus", small: true, led: engine.ccLEDs[MoveMap.down]) {
                        engine.tapButton(MoveMap.down)
                    }
                    Color.clear.frame(width: 30, height: 30)
                }
            }
            .frame(width: 120, alignment: .trailing)
        }
    }
}

// MARK: - Display

struct DisplayView: View {
    let image: CGImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(Color.black)
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.none)
                    .aspectRatio(2, contentMode: .fit)
                    .padding(8)
            }
        }
        .frame(width: 256, height: 136)
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.controlBorder))
    }
}

// MARK: - Pads & steps

struct PadView: View {
    let color: Color
    var pressColor: Color = .white
    let press: (Bool) -> Void
    @State private var down = false

    var body: some View {
        let lit = color != .clear
        let fill = down ? pressColor : (lit ? color : Theme.padOff)
        RoundedRectangle(cornerRadius: 7)
            .fill(fill)
            .overlay(RoundedRectangle(cornerRadius: 7)
                .strokeBorder(Color.white.opacity(down ? 0.6 : 0.22), lineWidth: 1))
            .shadow(color: down ? pressColor.opacity(0.8) : (lit ? color.opacity(0.55) : .clear),
                    radius: down ? 10 : 7)
            .frame(minWidth: 56, maxWidth: .infinity, minHeight: 58, maxHeight: .infinity)
            .scaleEffect(down ? 0.97 : 1)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !down { down = true; press(true) }
                }
                .onEnded { _ in down = false; press(false) })
    }
}

struct StepButton: View {
    let rgb: Int?
    let white: Int?
    let press: (Bool) -> Void
    @State private var down = false

    var body: some View {
        let fill: Color = {
            if let rgb, rgb > 0 { return MovePalette.color(rgb) }
            if let white, white > 0 { return MovePalette.whiteLED(white) }
            return Theme.control
        }()
        RoundedRectangle(cornerRadius: 5)
            .fill(fill)
            .overlay(RoundedRectangle(cornerRadius: 5)
                .strokeBorder(Color.white.opacity(down ? 0.6 : 0.22), lineWidth: 1))
            .frame(width: 40, height: 26)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !down { down = true; press(true) }
                }
                .onEnded { _ in down = false; press(false) })
    }
}

// MARK: - Buttons

struct TrackBar: View {
    let color: Color
    var glow = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Capsule()
                .fill(color == .clear ? Theme.control : color)
                .frame(width: 14)
                .frame(maxHeight: .infinity)
                .shadow(color: glow ? color.opacity(0.8) : .clear, radius: 6)
        }
        .buttonStyle(.plain)
    }
}

struct RoundButton: View {
    var symbol: String? = nil
    var text: String? = nil
    var small = false
    var size: CGFloat? = nil  // explicit diameter (overrides small/default)
    var led: Int? = nil      // white LED brightness
    var rgb: Int? = nil      // RGB palette index
    let action: () -> Void

    var body: some View {
        let dim: CGFloat = size ?? (small ? 30 : 42)
        let glow: Color = {
            if let rgb, rgb > 0 { return MovePalette.color(rgb) }
            if let led, led > 0 { return MovePalette.whiteLED(led) }
            return .clear
        }()
        Button(action: action) {
            ZStack {
                Circle().fill(Theme.control)
                Circle().strokeBorder(glow == .clear ? Theme.controlBorder : glow, lineWidth: 1.5)
                Group {
                    if let symbol {
                        Image(systemName: symbol).font(.system(size: dim * 0.32, weight: .semibold))
                    } else if let text {
                        Text(text).font(.system(size: dim * 0.34, weight: .semibold))
                    }
                }
                .foregroundStyle(glow == .clear ? Theme.label : .white)
            }
            .frame(width: dim, height: dim)
            .shadow(color: glow.opacity(0.6), radius: glow == .clear ? 0 : 6)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Knob with label

/// A knob plus the live parameter name + value beneath it, in tiny type.
struct KnobColumn<Content: View>: View {
    let name: String
    let value: String
    @ViewBuilder let knob: () -> Content

    var body: some View {
        VStack(spacing: 2) {
            knob()
            Text(name.isEmpty ? " " : name)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(Theme.label)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(value)
                .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1).minimumScaleFactor(0.6)
                .frame(height: 10)
        }
        .frame(width: 70)
    }
}

// MARK: - Status LEDs

/// Two faint indicators: red = engine alive, green = live output level.
struct StatusLEDs: View {
    let running: Bool
    let level: Double   // 0…1 smoothed peak

    var body: some View {
        VStack(spacing: 8) {
            Circle()
                .fill(Color.red)
                .frame(width: 7, height: 7)
                .opacity(running ? 0.55 : 0.12)
                .shadow(color: .red.opacity(running ? 0.5 : 0), radius: 3)
            Circle()
                .fill(Color.green)
                .frame(width: 7, height: 7)
                .opacity(0.12 + 0.88 * level)
                .shadow(color: .green.opacity(level), radius: 2 + 5 * level)
        }
        .frame(width: 12)
    }
}

// MARK: - Encoders

/// Relative encoder with a 270° value gauge. The gauge tracks the encoder's
/// own accumulated position (not the engine param yet — that needs per-knob
/// value plumbing), giving clear spatial feedback as you turn.
struct EncoderKnob: View {
    let size: CGFloat
    let onDelta: (Int) -> Void
    let onHover: (Bool) -> Void

    @State private var value: Double = 0.5     // 0…1 gauge position
    @State private var residual: CGFloat = 0
    @State private var lastY: CGFloat? = nil
    @State private var hovered = false

    private let pixelsPerDetent: CGFloat = 7
    private let perDetent = 0.03                // gauge units per detent
    private let arcWidth: CGFloat = 3

    var body: some View {
        let gaugeAngle = -135 + value * 270     // 0→lower-left, 1→lower-right

        ZStack {
            Circle().fill(Theme.control)
            Circle().strokeBorder(hovered ? Color.white.opacity(0.55) : Theme.controlBorder,
                                  lineWidth: 1)
            // 270° track + bright value fill, opening at the bottom
            Circle().trim(from: 0, to: 0.75)
                .stroke(Color.white.opacity(0.10),
                        style: StrokeStyle(lineWidth: arcWidth, lineCap: .round))
                .rotationEffect(.degrees(135))
                .padding(arcWidth)
            Circle().trim(from: 0, to: 0.75 * value)
                .stroke(hovered ? Color.white : Color.white.opacity(0.85),
                        style: StrokeStyle(lineWidth: arcWidth, lineCap: .round))
                .rotationEffect(.degrees(135))
                .padding(arcWidth)
            // position indicator
            Capsule()
                .fill(Color.white.opacity(0.95))
                .frame(width: 2.5, height: size * 0.22)
                .offset(y: -size * 0.24)
                .rotationEffect(.degrees(gaugeAngle))
        }
        .frame(width: size, height: size)
        .onHover { inside in
            hovered = inside
            onHover(inside)  // capacitive touch → param overlay on the display
        }
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { g in
                if lastY == nil {
                    lastY = g.location.y
                    #if !os(macOS)
                    onHover(true)  // no hover on touch: finger down = capacitive touch
                    #endif
                    return
                }
                let dy = lastY! - g.location.y
                lastY = g.location.y
                residual += dy
                let detents = Int(residual / pixelsPerDetent)
                if detents != 0 {
                    residual -= CGFloat(detents) * pixelsPerDetent
                    value = min(1, max(0, value + Double(detents) * perDetent))
                    onDelta(detents)
                }
            }
            .onEnded { _ in
                lastY = nil
                residual = 0
                #if !os(macOS)
                onHover(false)
                #endif
            })
    }
}

/// Jog wheel: visuals in SwiftUI, input via raw AppKit mouse tracking
/// (NSViewRepresentable) — SwiftUI gestures buffered drags during
/// disambiguation, which made rotation apply only on mouse-up.
/// Also supports two-finger scroll over the wheel.
struct JogWheel: View {
    let onDelta: (Int) -> Void
    let onPressBegan: () -> Void
    let onPressEnded: () -> Void
    let onPressCancelled: () -> Void
    let onHover: (Bool) -> Void

    @State private var spin: Double = 0

    private let size: CGFloat = 132

    var body: some View {
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Theme.control, Theme.well],
                                     center: .center, startRadius: 8, endRadius: size * 0.62))
            Circle().strokeBorder(Theme.controlBorder, lineWidth: 1.5)
            Circle()
                .fill(Color.white.opacity(0.75))
                .frame(width: 5, height: 5)
                .offset(y: -size * 0.38)
                .rotationEffect(.degrees(spin))
            JogMouseArea(onDelta: { d in
                spin += Double(d) * 12
                onDelta(d)
            }, onPressBegan: onPressBegan, onPressEnded: onPressEnded,
               onPressCancelled: onPressCancelled, onHover: onHover)
        }
        .frame(width: size, height: size)
    }
}

#if os(macOS)
private struct JogMouseArea: NSViewRepresentable {
    var onDelta: (Int) -> Void
    var onPressBegan: () -> Void
    var onPressEnded: () -> Void
    var onPressCancelled: () -> Void
    var onHover: (Bool) -> Void

    func makeNSView(context: Context) -> JogNSView {
        let v = JogNSView()
        update(v)
        return v
    }

    func updateNSView(_ v: JogNSView, context: Context) { update(v) }

    private func update(_ v: JogNSView) {
        v.onDelta = onDelta
        v.onPressBegan = onPressBegan
        v.onPressEnded = onPressEnded
        v.onPressCancelled = onPressCancelled
        v.onHover = onHover
    }
}

final class JogNSView: NSView {
    var onDelta: ((Int) -> Void)?
    var onPressBegan: (() -> Void)?
    var onPressEnded: (() -> Void)?
    var onPressCancelled: (() -> Void)?
    var onHover: ((Bool) -> Void)?

    private var lastAngle: CGFloat?
    private var residual: CGFloat = 0
    private var scrollAccum: CGFloat = 0
    private var moved: CGFloat = 0
    private var cancelled = false
    private var downPoint: NSPoint = .zero

    private let degreesPerDetent: CGFloat = 12
    private let scrollPerDetent: CGFloat = 8
    private let clickSlop: CGFloat = 4

    override var isFlipped: Bool { true }  /* match screen coords: CW = positive */

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }

    private func angle(_ p: NSPoint) -> CGFloat {
        atan2(p.y - bounds.midY, p.x - bounds.midX) * 180 / .pi
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        downPoint = p
        moved = 0
        cancelled = false
        lastAngle = angle(p)
        residual = 0
        onPressBegan?()
    }

    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        moved = max(moved, hypot(p.x - downPoint.x, p.y - downPoint.y))
        if !cancelled && moved >= clickSlop { cancelled = true; onPressCancelled?() }
        guard let last = lastAngle else { return }
        var d = angle(p) - last
        if d > 180 { d -= 360 } else if d < -180 { d += 360 }
        lastAngle = angle(p)
        residual += d
        let detents = Int(residual / degreesPerDetent)
        if detents != 0 {
            residual -= CGFloat(detents) * degreesPerDetent
            onDelta?(detents)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if moved < clickSlop { onPressEnded?() } else if !cancelled { onPressCancelled?() }
        lastAngle = nil
        residual = 0
    }

    override func scrollWheel(with event: NSEvent) {
        scrollAccum += event.scrollingDeltaY
        let detents = Int(scrollAccum / scrollPerDetent)
        if detents != 0 {
            scrollAccum -= CGFloat(detents) * scrollPerDetent
            onDelta?(detents)
        }
    }
}
#else
/// Touch jog: angle-tracking drag around the wheel center; a near-still tap
/// clicks. (No buffering issue on iOS — no competing gesture here.)
private struct JogMouseArea: View {
    var onDelta: (Int) -> Void
    var onPressBegan: () -> Void
    var onPressEnded: () -> Void
    var onPressCancelled: () -> Void
    var onHover: (Bool) -> Void

    @State private var lastAngle: CGFloat?
    @State private var residual: CGFloat = 0
    @State private var moved: CGFloat = 0
    @State private var cancelled = false
    @State private var downPoint: CGPoint = .zero

    private let degreesPerDetent: CGFloat = 20
    private let clickSlop: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            Color.clear
                .contentShape(Circle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let a = atan2(g.location.y - center.y, g.location.x - center.x) * 180 / .pi
                        guard let last = lastAngle else {
                            downPoint = g.location; moved = 0; cancelled = false
                            lastAngle = a; residual = 0
                            onHover(true)   // finger down = capacitive touch
                            onPressBegan()  // arm long-press / Shift+Vol combo
                            return
                        }
                        moved = max(moved, hypot(g.location.x - downPoint.x,
                                                 g.location.y - downPoint.y))
                        if !cancelled && moved >= clickSlop { cancelled = true; onPressCancelled() }
                        var d = a - last
                        if d > 180 { d -= 360 } else if d < -180 { d += 360 }
                        lastAngle = a
                        residual += d
                        let detents = Int(residual / degreesPerDetent)
                        if detents != 0 {
                            residual -= CGFloat(detents) * degreesPerDetent
                            onDelta(detents)
                        }
                    }
                    .onEnded { _ in
                        if moved < clickSlop { onPressEnded() } else if !cancelled { onPressCancelled() }
                        lastAngle = nil
                        residual = 0
                        onHover(false)
                    })
        }
    }
}
#endif
