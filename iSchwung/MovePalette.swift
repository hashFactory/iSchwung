import SwiftUI

/// The Move's 128-entry indexed RGB LED palette. Parsed at runtime from the
/// palette comment block in schwung's shared/constants.mjs (single source of
/// truth, survives upstream palette edits without a code change here).
enum MovePalette {

    static let colors: [Int: Color] = load()

    static func color(_ index: Int) -> Color {
        if index <= 0 { return .clear }
        return colors[index] ?? Color(white: 0.75)
    }

    /// White-LED brightness (0-127) for the non-RGB buttons.
    static func whiteLED(_ value: Int) -> Color {
        guard value > 0 else { return .clear }
        return Color.white.opacity(0.25 + 0.75 * Double(min(value, 127)) / 127.0)
    }

    private static func load() -> [Int: Color] {
        #if os(iOS) && !targetEnvironment(simulator)
        let path = (Bundle.main.resourcePath ?? "") + "/runtime/schwung/shared/constants.mjs"
        #else
        let path = SchwungEngine.projectRoot + "/git-schwung/src/shared/constants.mjs"
        #endif
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [:] }
        var out: [Int: Color] = [:]
        // Comment-table lines look like: "  1 : #FF2424  Bright Red"
        guard let regex = try? NSRegularExpression(
            pattern: #"^\s*(\d{1,3})\s*:\s*#([0-9A-Fa-f]{6})"#,
            options: [.anchorsMatchLines]) else { return [:] }
        let ns = text as NSString
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let idx = Int(ns.substring(with: m.range(at: 1))), idx < 128,
                  let rgb = UInt32(ns.substring(with: m.range(at: 2)), radix: 16) else { continue }
            out[idx] = Color(red: Double((rgb >> 16) & 0xFF) / 255.0,
                             green: Double((rgb >> 8) & 0xFF) / 255.0,
                             blue: Double(rgb & 0xFF) / 255.0)
        }
        return out
    }
}
