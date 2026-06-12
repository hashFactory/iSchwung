import SwiftUI
import Combine
import Accelerate

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
    static let controlBorder = Color.white.opacity(0.42)
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
    let engine: SchwungEngine

    var body: some View {
        #if os(macOS)
        surface(overscanX: 0)
        #else
        // Fixed-layout surface scaled to whatever screen we get (best in
        // landscape). overscanX = how far past the surface edge the letterbox
        // bars run, in unscaled points, so the graph can bleed to the screen edge.
        GeometryReader { geo in
            let scale = min(geo.size.width / 1180, geo.size.height / 600)
            let overscanX = max(0, (geo.size.width - 1180 * scale) / (2 * scale))
            surface(overscanX: overscanX)
                .scaleEffect(scale)
                .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(Theme.well)
        .overlay(TouchIndicator().allowsHitTesting(false))   // faint circle per touch
        .ignoresSafeArea()
        .statusBarHidden()
        #endif
    }

    private func surface(overscanX: CGFloat) -> some View {
        VStack(spacing: 12) {
            topRow
            middleRow
            bottomRow
            // Graph rises up behind the bottom controls (d-pad/buttons occlude
            // its top edge) and bleeds past the padding to the real screen edges:
            // its 0-line sits on the bottom pixel, full width into the letterbox.
            IntensityStrip(height: 60)
                .padding(.top, -34)
                .padding(.horizontal, -(16 + overscanX))
                .zIndex(-1)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .frame(width: 1180, height: 600)
        .background(Theme.body)
        .overlay(alignment: .bottomLeading) { StatusText(engine: engine) }
    }

    private var topRow: some View {
        HStack(alignment: .center, spacing: 14) {
            DisplayCell(engine: engine)
            Spacer(minLength: 8)
            ForEach(0..<8, id: \.self) { i in
                KnobCell(engine: engine, index: i)
            }
            StatusLEDsCell(engine: engine)
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
                        CCButton(engine: engine, cc: MoveMap.back, symbol: "chevron.left", size: 50)
                        CCButton(engine: engine, cc: MoveMap.menu, symbol: "line.3.horizontal", size: 50)
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
                TrackBarCell(engine: engine, index: idx, cc: cc)
            }
        }
    }

    private var padGrid: some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            ForEach(0..<4, id: \.self) { row in
                GridRow {
                    ForEach(0..<8, id: \.self) { col in
                        PadCell(engine: engine, note: MoveMap.pad(row: row, col: col))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        // One multitouch layer over the whole grid so a finger sliding across pads
        // retriggers each — glissando, like a real Move. Replaces the per-pad taps.
        .overlay(PadTouchSurface(engine: engine))
    }

    private var rightButtons: some View {
        Grid(horizontalSpacing: 12, verticalSpacing: 16) {
            GridRow {
                CCButton(engine: engine, cc: MoveMap.capture, symbol: "viewfinder")
                CCButton(engine: engine, cc: MoveMap.sample, symbol: "circle.fill", rgb: true)
            }
            GridRow {
                CCButton(engine: engine, cc: MoveMap.loop, symbol: "repeat")
                CCButton(engine: engine, cc: MoveMap.mute, text: "M")
            }
            GridRow {
                CCButton(engine: engine, cc: MoveMap.delete, symbol: "xmark")
                CCButton(engine: engine, cc: MoveMap.copy, symbol: "square.on.square")
            }
            GridRow {
                CCButton(engine: engine, cc: MoveMap.undo, symbol: "arrow.uturn.backward")
                ShiftButton(engine: engine)
            }
        }
        .frame(width: 130)
    }

    private var bottomRow: some View {
        HStack(spacing: 18) {
            HStack(spacing: 12) {
                PlayButton(engine: engine)
                CCButton(engine: engine, cc: MoveMap.rec, symbol: "record.circle", rgb: true)
            }
            .frame(width: 150, alignment: .leading)

            HStack(spacing: 8) {
                ForEach(MoveMap.steps, id: \.self) { note in
                    StepCell(engine: engine, note: note)
                }
            }
            .frame(maxWidth: .infinity)

            // compact d-pad cross: + / − vertical, ‹ / › horizontal
            Grid(horizontalSpacing: 5, verticalSpacing: 5) {
                GridRow {
                    Color.clear.frame(width: 30, height: 30)
                    CCButton(engine: engine, cc: MoveMap.up, symbol: "plus", small: true)
                    Color.clear.frame(width: 30, height: 30)
                }
                GridRow {
                    CCButton(engine: engine, cc: MoveMap.left, symbol: "chevron.left", small: true)
                    Color.clear.frame(width: 30, height: 30)
                    CCButton(engine: engine, cc: MoveMap.right, symbol: "chevron.right", small: true)
                }
                GridRow {
                    Color.clear.frame(width: 30, height: 30)
                    CCButton(engine: engine, cc: MoveMap.down, symbol: "minus", small: true)
                    Color.clear.frame(width: 30, height: 30)
                }
            }
            .frame(width: 120, alignment: .trailing)
        }
    }
}

// MARK: - Engine-bound leaf cells
//
// Each cell reads only its own slice of the @Observable engine, so a change to
// one property (e.g. an LED) re-evaluates just these tiny leaves — never the
// whole surface. The parent `MoveSurfaceView` body reads no observable property,
// so it subscribes to nothing and is evaluated once.

/// One of the 8 top encoders + its live name/value label.
struct KnobCell: View {
    let engine: SchwungEngine
    let index: Int
    var body: some View {
        KnobColumn(name: engine.knobNames[index], value: engine.knobValues[index]) {
            EncoderKnob(size: 68, norm: engine.knobNorm[index],
                        onDelta: { engine.sendEncoder(MoveMap.knobs[index], delta: $0) },
                        onSetNorm: { engine.setKnobNorm(index: index, norm: $0) },
                        onHover: { engine.encoderHover(cc: MoveMap.knobs[index],
                                                       touchNote: MoveMap.knobTouch[index],
                                                       inside: $0) })
        }
    }
}

/// A round button whose LED follows a CC. `rgb` picks the RGB-palette vs.
/// white-brightness interpretation of the same `ccLEDs[cc]` value.
struct CCButton: View {
    let engine: SchwungEngine
    let cc: Int
    var symbol: String? = nil
    var text: String? = nil
    var small = false
    var size: CGFloat? = nil
    var rgb = false
    var body: some View {
        let v = engine.ccLEDs[cc]
        RoundButton(symbol: symbol, text: text, small: small, size: size,
                    led: rgb ? nil : v, rgb: rgb ? v : nil) { engine.tapButton(cc) }
    }
}

struct ShiftButton: View {
    let engine: SchwungEngine
    var body: some View {
        RoundButton(symbol: "shift.fill", led: engine.shiftHeld ? 127 : 0) { engine.toggleShift() }
    }
}

struct PlayButton: View {
    let engine: SchwungEngine
    var body: some View {
        RoundButton(symbol: engine.isPlaying ? "stop.fill" : "play.fill",
                    led: engine.isPlaying ? 127 : 0) { engine.togglePlay() }
    }
}

struct TrackBarCell: View {
    let engine: SchwungEngine
    let index: Int
    let cc: Int
    var body: some View {
        let led = MovePalette.color(engine.ccLEDs[cc] ?? 0)
        let base = led == .clear ? Theme.trackColors[index] : led
        let sel = engine.selectedSlot == index
        TrackBar(color: base.opacity(sel ? 1.0 : 0.45), glow: sel) { engine.tapButton(cc) }
    }
}

struct PadCell: View {
    let engine: SchwungEngine
    let note: Int
    var body: some View {
        let slot = engine.selectedSlot
        let defaultColor = engine.slotActive[slot]
            ? Theme.trackColors[slot].opacity(0.32) : Color.clear
        let led = MovePalette.color(engine.noteLEDs[note] ?? 0)
        PadView(color: led == .clear ? defaultColor : led,
                pressColor: Theme.trackColors[slot],
                down: engine.padDown.contains(note))
    }
}

struct StepCell: View {
    let engine: SchwungEngine
    let note: Int
    var body: some View {
        StepButton(rgb: engine.noteLEDs[note], white: engine.ccLEDs[note],
                   press: { engine.sendNote(note, on: $0) })
    }
}

struct DisplayCell: View {
    let engine: SchwungEngine
    var body: some View { DisplayView(image: engine.displayImage) }
}

struct StatusText: View {
    let engine: SchwungEngine
    var body: some View {
        Text(engine.status)
            .font(.system(size: 9, design: .monospaced))
            .foregroundStyle(Theme.label.opacity(0.5))
            .padding(.leading, 26).padding(.bottom, 8)
    }
}

struct StatusLEDsCell: View {
    let engine: SchwungEngine
    var body: some View { StatusLEDs(running: engine.engineRunning) }
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
    let down: Bool   // driven by the grid's sweep layer (see PadSweep.swift)

    var body: some View {
        let lit = color != .clear
        let fill = down ? pressColor : (lit ? color : Theme.padOff)
        RoundedRectangle(cornerRadius: 7)
            .fill(fill)
            .overlay(RoundedRectangle(cornerRadius: 7)
                .strokeBorder(Color.white.opacity(down ? 0.7 : 0.40), lineWidth: 1))
            .shadow(color: down ? pressColor.opacity(0.8) : (lit ? color.opacity(0.55) : .clear),
                    radius: down ? 10 : 7)
            .frame(minWidth: 56, maxWidth: .infinity, minHeight: 58, maxHeight: .infinity)
            .scaleEffect(down ? 0.97 : 1)
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
                .strokeBorder(Color.white.opacity(down ? 0.7 : 0.40), lineWidth: 1))
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
        VStack(spacing: 3) {
            knob()
            Text(name.isEmpty ? " " : name)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .textCase(.uppercase)
                .tracking(0.8)
                .foregroundStyle(Theme.label)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(value)
                .font(.system(size: 13.5, weight: .bold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1).minimumScaleFactor(0.6)
                .frame(height: 16)
        }
        .frame(width: 78)
    }
}

// MARK: - Status LEDs

/// Two faint indicators: red = engine alive, green = live output level. The
/// green level is polled here (own @State + timer) rather than coming from the
/// engine as @Published — otherwise it would invalidate the whole surface ~30×/s.
struct StatusLEDs: View {
    let running: Bool

    @State private var level: Double = 0
    @State private var timer: Timer?

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
        .onAppear {
            guard timer == nil else { return }
            let t = Timer(timeInterval: 1.0 / 20.0, repeats: true) { _ in
                let peak = Double(min(schwung_audio_peak(), 1))
                let next = peak > level ? peak : level * 0.8 + peak * 0.2   // fast attack, soft decay
                if abs(next - level) > 0.004 { level = next }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
        .onDisappear { timer?.invalidate(); timer = nil }
    }
}

// MARK: - Intensity graph

/// A continuous trace of output intensity: a bright line whose fill fades down
/// through gray to black, newest at the right. The whole thing is drawn by a
/// per-pixel Metal shader (`IntensityGraph.metal`) — the CPU only hands over the
/// sample array each frame, so it's effectively free. Sits behind the bottom
/// controls, which occlude its top edge.
struct IntensityStrip: View {
    var height: CGFloat = 30
    @StateObject private var model = IntensityModel()

    var body: some View {
        // @StateObject re-evaluates this isolated view on the 30 Hz ring advance;
        // the only CPU work is handing the sample array to the shader, which
        // rasterizes the line + fade per-pixel on the GPU.
        Rectangle()
            .fill(.black)
            .colorEffect(ShaderLibrary.intensityGraph(
                .boundingRect,
                .floatArray(model.samples())))
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .onAppear { model.start() }
            .onDisappear { model.stop() }
    }
}

/// Samples output intensity (perceptual RMS of the capture ring) at 60 Hz into a
/// 20-second ring and bumps `tick` so the Canvas redraws.
@MainActor
final class IntensityModel: ObservableObject {
    @Published private(set) var tick: Int = 0

    private let rate = 30          // a slow envelope line is smooth at 30 fps
    private let seconds = 12
    private let win = 1024
    private var ring: [Float]
    private var w = 0
    private var smoothed: Float = 0
    private var buf: [Float]
    private var timer: Timer?

    init() {
        ring = [Float](repeating: 0, count: rate * seconds)
        buf = [Float](repeating: 0, count: win)
    }

    /// Snapshot of the ring in chronological order (oldest first).
    func samples() -> [Float] {
        let n = ring.count
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n { out[i] = ring[(w + i) % n] }
        return out
    }

    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / Double(rate), repeats: true) { [weak self] _ in
            Task { @MainActor in self?.advance() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func advance() {
        var rms: Float = 0
        let got = buf.withUnsafeMutableBufferPointer {
            Int(schwung_audio_capture($0.baseAddress, Int32(win)))
        }
        if got == win { vDSP_rmsqv(buf, 1, &rms, vDSP_Length(win)) }
        // Perceptual lift (rms is small) + asymmetric smoothing: snappy rise,
        // gentle fall, so the line reads as a continuous intensity envelope.
        let lifted = min(1, sqrtf(rms) * 1.6)
        smoothed = lifted > smoothed ? lifted : smoothed * 0.85 + lifted * 0.15
        ring[w] = smoothed
        w = (w + 1) % ring.count
        tick &+= 1
    }
}

// MARK: - Encoders

/// Relative encoder with a 270° value gauge. When the chain reports the mapped
/// parameter's normalized value (`norm` ≥ 0) the gauge mirrors the real value
/// and range; unmapped knobs fall back to a fine local accumulator just for
/// turn feedback.
struct EncoderKnob: View {
    let size: CGFloat
    var norm: Double = -1                       // engine value 0…1, <0 = unmapped
    let onDelta: (Int) -> Void
    var onSetNorm: ((Double) -> Void)? = nil    // absolute set for mapped knobs
    let onHover: (Bool) -> Void

    @State private var localValue: Double = 0.5  // fallback when unmapped
    @State private var residual: CGFloat = 0
    @State private var lastX: CGFloat? = nil
    @State private var dragStartNorm: Double = 0
    @State private var hovered = false

    private let pixelsPerDetent: CGFloat = 7
    private let perDetent = 0.012               // fine, so unmapped turns don't jump
    private let arcWidth: CGFloat = 3
    // Full min→max sweep takes ~2 surface widths (≈ 2 phone lengths in landscape)
    // of horizontal drag, regardless of how many steps the param has.
    private let fullSweepPoints: CGFloat = 2360

    var body: some View {
        let mapped = norm >= 0
        let value = mapped ? norm : localValue
        let gaugeAngle = -135 + value * 270     // 0→lower-left, 1→lower-right

        ZStack {
            Circle().fill(Theme.control)
            Circle().strokeBorder(hovered ? Color.white : Color.white.opacity(0.45),
                                  lineWidth: 1.25)
            // 270° track + bright value fill, opening at the bottom
            Circle().trim(from: 0, to: 0.75)
                .stroke(Color.white.opacity(0.16),
                        style: StrokeStyle(lineWidth: arcWidth, lineCap: .round))
                .rotationEffect(.degrees(135))
                .padding(arcWidth)
            Circle().trim(from: 0, to: 0.75 * value)
                .stroke(mapped ? Color.white : Color.white.opacity(0.6),  // dimmer when not a real value
                        style: StrokeStyle(lineWidth: arcWidth, lineCap: .round))
                .rotationEffect(.degrees(135))
                .padding(arcWidth)
            // position indicator: a solid white hand from the center to the rim
            Path { p in
                p.move(to: CGPoint(x: size / 2, y: size / 2))
                p.addLine(to: CGPoint(x: size / 2, y: size * 0.08))
            }
            .stroke(Color.white.opacity(mapped ? 1.0 : 0.7),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(gaugeAngle))
        }
        .frame(width: size, height: size)
        .onHover { inside in
            hovered = inside
            onHover(inside)  // capacitive touch → param overlay on the display
        }
        // First touch establishes (selects) the knob; sliding left/right then
        // lowers/raises the value, like dragging a horizontal slider.
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { g in
                if lastX == nil {
                    lastX = g.location.x          // anchor the drag
                    dragStartNorm = mapped ? norm : localValue
                    #if !os(macOS)
                    onHover(true)  // no hover on touch: finger down = capacitive touch
                    #endif
                    return
                }
                if mapped, let onSetNorm {
                    // Absolute: map distance from the anchor to a 0…1 target so
                    // full range is a fixed drag regardless of step count.
                    let dx = g.location.x - lastX!
                    onSetNorm(min(1, max(0, dragStartNorm + Double(dx / fullSweepPoints))))
                } else {
                    // Unmapped (e.g. master volume): relative detents.
                    let dx = g.location.x - lastX!
                    lastX = g.location.x
                    residual += dx
                    let detents = Int(residual / pixelsPerDetent)
                    if detents != 0 {
                        residual -= CGFloat(detents) * pixelsPerDetent
                        localValue = min(1, max(0, localValue + Double(detents) * perDetent))
                        onDelta(detents)
                    }
                }
            }
            .onEnded { _ in
                lastX = nil
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
