import SwiftUI
import Combine
#if os(macOS)
import AppKit
#else
import AVFAudio
#endif

/// Hosts the schwung shadow UI engine (QuickJS + shadow_ui.js running on a
/// background thread inside libschwungcore) and bridges it to SwiftUI:
/// framebuffer polling, LED state from the MIDI-out ring, control input in.
@MainActor
final class SchwungEngine: ObservableObject {

    @Published var displayImage: CGImage?
    @Published var noteLEDs: [Int: Int] = [:]   // note (pads 68-99, steps 16-31) → palette index
    @Published var ccLEDs: [Int: Int] = [:]     // cc (tracks 40-43, buttons) → palette index / brightness
    @Published var shiftHeld = false
    @Published var status: String = "starting…"
    @Published var selectedSlot = 0
    @Published var slotActive = [false, false, false, false]
    @Published var engineRunning = false       // red status LED
    @Published var audioLevel: Double = 0       // 0…1 smoothed output peak (green LED)
    @Published var knobNames = [String](repeating: "", count: 8)   // live per-knob param name
    @Published var knobValues = [String](repeating: "", count: 8)  // live per-knob value
    @Published var knobNorm = [Double](repeating: -1, count: 8)    // 0…1 gauge pos, -1 = unmapped
    @Published var isPlaying = false           // our MIDI clock transport (drives sequencer FX)

    /// Dev PoC: the freshly cloned schwung repo this app feeds from.
    static let projectRoot = "/Users/tristan/Desktop/iSchwung"

    private var pollTimer: Timer?
    private var lastGeneration: UInt32 = 0
    private var started = false

    var dataRoot: String {
        #if os(iOS) && targetEnvironment(simulator)
        // Simulator sees the host FS: use the tree prepared by
        // `TARGET=iossim sync-runtime.sh native/build/ios-data` directly.
        return Self.projectRoot + "/native/build/ios-data"
        #elseif os(iOS)
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("data").path
        #else
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask)[0]
        return appSupport.appendingPathComponent("iSchwung/data").path
        #endif
    }

    func start() {
        guard !started else { return }
        started = true
        NSLog("iSchwung: engine.start, dataRoot=%@", dataRoot)

        do {
            try syncRuntimeRoot()
        } catch {
            status = "runtime sync failed: \(error.localizedDescription)"
            NSLog("iSchwung: %@", status)
            return
        }

        #if !os(macOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setPreferredSampleRate(44100)   // match the 44.1kHz engine
        try? session.setPreferredIOBufferDuration(0.005)
        try? session.setActive(true)
        NSLog("iSchwung: audio session sr=%.0f ioBuf=%.4f outCh=%ld",
              session.sampleRate, session.ioBufferDuration, session.outputNumberOfChannels)
        #endif
        #if os(iOS) && !targetEnvironment(simulator)
        // Library validation: module dylibs only dlopen from inside the bundle.
        if let fw = Bundle.main.privateFrameworksPath { schwung_set_dylib_dir(fw) }
        #endif

        schwung_set_data_root(dataRoot)
        let script = dataRoot + "/schwung/shadow/shadow_ui.js"
        if schwung_engine_start(script) != 0 {
            status = "engine failed to start"
            return
        }
        status = "running"
        engineRunning = true
        installShiftKeyMonitor()
        installArrowKeyMonitor()

        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func stop() {
        schwung_engine_stop()
        pollTimer?.invalidate()
    }

    // MARK: - Input from the virtual surface

    func sendNote(_ note: Int, on: Bool, velocity: Int = 100) {
        schwung_send_internal_midi(on ? 0x90 : 0x80, UInt8(note), UInt8(on ? velocity : 0))
    }

    func sendCC(_ cc: Int, _ value: Int) {
        schwung_send_internal_midi(0xB0, UInt8(cc), UInt8(value))
    }

    /// Momentary button press (CC 127 then 0).
    func tapButton(_ cc: Int) {
        sendCC(cc, 127)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) { [weak self] in
            self?.sendCC(cc, 0)
        }
    }

    /// Play toggles our standalone MIDI clock (the only transport source here),
    /// which sends Start/Stop + 24-PPQN ticks to every chain so sequencer MIDI
    /// FX (euclidrum, clock-synced arps) advance. Also flashes the JS play LED.
    func togglePlay() {
        isPlaying.toggle()
        schwung_set_transport(isPlaying ? 1 : 0)
        sendCC(MoveMap.play, isPlaying ? 127 : 0)
    }

    /// Relative encoder: delta in detents, encoded 1-63 CW / 65-127 CCW.
    func sendEncoder(_ cc: Int, delta: Int) {
        guard delta != 0 else { return }
        let v = delta > 0 ? min(delta, 63) : 128 + max(delta, -63)
        sendCC(cc, v)
    }

    /// Capacitive touch: hardware sends note-on 127 on touch and note-on
    /// velocity 0 on release (the JS checks 0x90 + vel==0, not note-off).
    func sendTouch(_ note: Int, on: Bool) {
        schwung_send_internal_midi(0x90, UInt8(note), on ? 127 : 0)
        if note == MoveMap.masterTouch { masterTouched = on }
    }

    // MARK: - Settings summon gesture
    //
    // On hardware the firmware shim watches for the configured summon gesture
    // and raises SHADOW_UI_FLAG_JUMP_TO_SETTINGS (0x40). Our compat layer
    // replaced the shim, so we reproduce both gestures here.

    private static let JUMP_TO_SETTINGS: UInt8 = 0x40
    private static let longPressDelay: TimeInterval = 0.5
    private var masterTouched = false
    private var jogPressToken: UUID?
    private var jogConsumed = false

    /// Open Global Settings (used by both summon gestures and the gear button).
    func jumpToSettings() {
        schwung_set_ui_flags(Self.JUMP_TO_SETTINGS)
    }

    /// Jog click pressed. Shift+Vol+Jog fires immediately; otherwise arm a
    /// long-press timer that opens settings if the finger stays down.
    func jogPressBegan() {
        jogConsumed = false
        if shiftHeld && masterTouched { jumpToSettings(); jogConsumed = true; return }
        let token = UUID()
        jogPressToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.longPressDelay) { [weak self] in
            guard let self, self.jogPressToken == token else { return }
            self.jogPressToken = nil
            self.jogConsumed = true
            self.jumpToSettings()
        }
    }

    /// Jog click released without turning. Cancels the long-press; if neither
    /// gesture fired, it's a normal jog click.
    func jogPressEnded() {
        jogPressToken = nil
        if jogConsumed { jogConsumed = false; return }
        tapButton(MoveMap.jogClick)
    }

    /// The press became a rotation — not a click. Disarm everything.
    func jogPressCancelled() {
        jogPressToken = nil
        jogConsumed = false
    }

    // MARK: - Hover + keyboard nudge

    /// Encoder under the cursor: (cc, whether up-arrow means negative delta —
    /// jog menus scroll down on CW, so "up" must turn CCW there).
    private var hoveredEncoder: (cc: Int, invertArrows: Bool)? = nil

    func encoderHover(cc: Int, touchNote: Int?, invertArrows: Bool = false, inside: Bool) {
        if inside {
            hoveredEncoder = (cc, invertArrows)
            if let touchNote { sendTouch(touchNote, on: true) }
        } else {
            if hoveredEncoder?.cc == cc { hoveredEncoder = nil }
            if let touchNote { sendTouch(touchNote, on: false) }
        }
    }

    /// ↑/↓ nudge the hovered encoder; key repeat gives continuous nudges.
    /// Event monitors run on the main thread, but the closure is nonisolated —
    /// assumeIsolated lets us read hover state synchronously to decide whether
    /// to consume the event.
    private func installArrowKeyMonitor() {
        #if os(macOS)
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.keyCode == 126 || event.keyCode == 125 else { return event }
            return MainActor.assumeIsolated {
                guard let enc = self.hoveredEncoder else { return event }
                var delta = event.keyCode == 126 ? 1 : -1
                if enc.invertArrows { delta = -delta }
                self.sendEncoder(enc.cc, delta: delta)
                return nil  // consumed
            }
        }
        #endif
    }

    /// Shift via the on-screen button is a toggle (a mouse can't hold two
    /// things); the physical ⇧ key is momentary and overrides it.
    func toggleShift() {
        setShift(!shiftHeld)
    }

    func setShift(_ held: Bool) {
        guard held != shiftHeld else { return }
        shiftHeld = held
        schwung_set_shift_held(held ? 1 : 0)
        sendCC(49, held ? 127 : 0)
    }

    /// Physical ⇧ key on the keyboard holds the Move's Shift button down,
    /// so click combos like Shift+Step or Shift+Knob work.
    private func installShiftKeyMonitor() {
        #if os(macOS)
        NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in
                self?.setShift(event.modifierFlags.contains(.shift))
            }
            return event
        }
        #endif
    }

    // MARK: - Polling

    private var pollCount = 0

    /// Pull the live name+value the chain mapped to each of the 8 knobs.
    private func pollKnobLabels() {
        var names = [String](repeating: "", count: 8)
        var values = [String](repeating: "", count: 8)
        var norms = [Double](repeating: -1, count: 8)
        var nbuf = [CChar](repeating: 0, count: 32)
        var vbuf = [CChar](repeating: 0, count: 32)
        var norm: Float = -1
        for k in 0..<8 {
            if schwung_knob_label(Int32(k), &nbuf, 32, &vbuf, 32, &norm) != 0 {
                // Chain returns "target: param" (e.g. "synth: cutoff") — show just the param.
                let raw = String(cString: nbuf)
                names[k] = raw.contains(": ") ? String(raw.split(separator: ":", maxSplits: 1)[1])
                    .trimmingCharacters(in: .whitespaces) : raw
                values[k] = String(cString: vbuf)
                norms[k] = Double(norm)
            }
        }
        // Most patches define no performance-macro mappings, so the chain
        // reports nothing above. Fall back to the sound generator's own default
        // knob layout (ui_hierarchy root `knobs` + chain_params) so the common
        // "synth loaded, editing it" case still shows names/values/gauges.
        synthKnobFallback(&names, &values, &norms)

        if names != knobNames { knobNames = names }
        if values != knobValues { knobValues = values }
        if norms != knobNorm { knobNorm = norms }
    }

    private struct ParamMeta { let name, type: String; let min, max: Double; let options: [String] }

    /// Generic get_param against the shown chain slot (synth:/fx1: prefixes etc.).
    private func chainParam(_ key: String) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        return schwung_chain_param(-1, key, &buf, 4096) > 0 ? String(cString: buf) : nil
    }

    /// Fill any still-unlabeled knobs from the synth's default knob assignment.
    private func synthKnobFallback(_ names: inout [String], _ values: inout [String],
                                   _ norms: inout [Double]) {
        guard names.contains("") else { return }
        guard let hier = chainParam("synth:ui_hierarchy")?.data(using: .utf8),
              let top = (try? JSONSerialization.jsonObject(with: hier)) as? [String: Any],
              let levels = top["levels"] as? [String: Any],
              let root = levels["root"] as? [String: Any],
              let knobs = root["knobs"] as? [String] else { return }

        var meta: [String: ParamMeta] = [:]
        if let cp = chainParam("synth:chain_params")?.data(using: .utf8),
           let arr = (try? JSONSerialization.jsonObject(with: cp)) as? [[String: Any]] {
            for p in arr {
                guard let key = p["key"] as? String else { continue }
                meta[key] = ParamMeta(name: (p["name"] as? String) ?? key,
                                      type: (p["type"] as? String) ?? "float",
                                      min: (p["min"] as? NSNumber)?.doubleValue ?? 0,
                                      max: (p["max"] as? NSNumber)?.doubleValue ?? 1,
                                      options: (p["options"] as? [String]) ?? [])
            }
        }

        for k in 0..<8 where names[k].isEmpty && k < knobs.count {
            let key = knobs[k]
            let m = meta[key]
            names[k] = m?.name ?? key
            guard let raw = chainParam("synth:\(key)")?.trimmingCharacters(in: .whitespaces) else { continue }
            if let m, m.type == "enum", let idx = Int(raw), idx >= 0, idx < m.options.count {
                values[k] = m.options[idx]
                norms[k] = m.options.count > 1 ? Double(idx) / Double(m.options.count - 1) : 0
            } else if let v = Double(raw) {
                values[k] = v == v.rounded() && abs(v) >= 1 ? String(Int(v)) : String(format: "%.2f", v)
                if let m, m.max > m.min { norms[k] = Swift.max(0, Swift.min(1, (v - m.min) / (m.max - m.min))) }
            } else {
                values[k] = raw
            }
        }
    }

    private func poll() {
        let peak = Double(min(schwung_audio_peak(), 1))
        // Fast attack, ~150ms decay → lively but readable green LED.
        audioLevel = peak > audioLevel ? peak : audioLevel * 0.8 + peak * 0.2
        if peak > 0.001 || status.hasPrefix("running ") {
            status = String(format: "running  ▮ %.0f%%", peak * 100)
        }
        let gen = schwung_display_generation()
        if gen != lastGeneration {
            lastGeneration = gen
            displayImage = Self.renderDisplay(schwung_display_buffer())
        }

        let sel = Int(schwung_selected_slot())
        if sel != selectedSlot { selectedSlot = sel }
        for s in 0..<4 {
            let active = schwung_slot_active(Int32(s)) != 0
            if active != slotActive[s] { slotActive[s] = active }
        }

        pollCount &+= 1
        if pollCount % 3 == 0 { pollKnobLabels() }   // ~10 Hz

        var buf = [UInt8](repeating: 0, count: 512)
        let n = Int(schwung_drain_midi_out(&buf, 512))
        if n >= 4 {
            for i in stride(from: 0, to: n, by: 4) {
                let cable = (buf[i] >> 4) & 0x0F
                guard cable == 0 else { continue }
                let type = buf[i + 1] & 0xF0
                let d1 = Int(buf[i + 2]), d2 = Int(buf[i + 3])
                if type == 0x90 {
                    noteLEDs[d1] = d2
                } else if type == 0xB0 {
                    ccLEDs[d1] = d2
                }
            }
        }
    }

    /// 1024-byte packed 1-bit framebuffer → 128x64 grayscale CGImage.
    /// Packing: band y8 in 0..<8, column x in 0..<128, bit n = row y8*8+n.
    private static func renderDisplay(_ fb: UnsafePointer<UInt8>?) -> CGImage? {
        guard let fb else { return nil }
        var pixels = [UInt8](repeating: 0, count: 128 * 64)
        for band in 0..<8 {
            for x in 0..<128 {
                let byte = fb[band * 128 + x]
                if byte == 0 { continue }
                for bit in 0..<8 where (byte >> bit) & 1 == 1 {
                    pixels[(band * 8 + bit) * 128 + x] = 255
                }
            }
        }
        return pixels.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: 128, height: 64,
                                      bitsPerComponent: 8, bytesPerRow: 128,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
            return ctx.makeImage()
        }
    }

    // MARK: - Runtime root

    /// Populates the /data/UserData stand-in from the schwung checkout via
    /// native/sync-runtime.sh (single source of truth for the layout).
    /// iOS can't spawn processes — the simulator uses a host tree prepared by
    /// running the script with TARGET=iossim at build time.
    private func syncRuntimeRoot() throws {
        #if os(macOS)
        let script = Self.projectRoot + "/native/sync-runtime.sh"
        guard FileManager.default.fileExists(atPath: script) else {
            throw NSError(domain: "iSchwung", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "sync-runtime.sh not found at \(script)"])
        }
        try FileManager.default.createDirectory(atPath: dataRoot, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = [script, dataRoot]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw NSError(domain: "iSchwung", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "sync-runtime.sh exited \(p.terminationStatus)"])
        }
        #elseif targetEnvironment(simulator)
        guard FileManager.default.fileExists(atPath: dataRoot + "/schwung/shadow/shadow_ui.js") else {
            throw NSError(domain: "iSchwung", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "run: TARGET=iossim native/sync-runtime.sh native/build/ios-data"])
        }
        #else
        // Device: merge-copy the bundled runtime into Documents — overwrite
        // shipped files, keep user data (patches/, slot_state/, …) untouched.
        guard let bundled = Bundle.main.resourceURL?.appendingPathComponent("runtime") else {
            throw NSError(domain: "iSchwung", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "bundled runtime missing"])
        }
        try mergeCopy(from: bundled, to: URL(fileURLWithPath: dataRoot))
        #endif
    }

    #if os(iOS) && !targetEnvironment(simulator)
    private func mergeCopy(from src: URL, to dst: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)
        for name in try fm.contentsOfDirectory(atPath: src.path) {
            let s = src.appendingPathComponent(name), d = dst.appendingPathComponent(name)
            var isDir: ObjCBool = false
            fm.fileExists(atPath: s.path, isDirectory: &isDir)
            if isDir.boolValue {
                try mergeCopy(from: s, to: d)
            } else {
                // Skip unchanged big files (the soundfont) by size
                if let a = try? fm.attributesOfItem(atPath: d.path),
                   let b = try? fm.attributesOfItem(atPath: s.path),
                   a[.size] as? UInt64 == b[.size] as? UInt64,
                   (b[.size] as? UInt64 ?? 0) > 1_000_000 { continue }
                try? fm.removeItem(at: d)
                try fm.copyItem(at: s, to: d)
            }
        }
    }
    #endif
}
