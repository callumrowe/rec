import Foundation

/// Terminal styling. Colour is on only for a TTY without NO_COLOR; everything
/// degrades to the same text without escapes, so logs and pipes stay clean.
enum Style {
    static let enabled: Bool = {
        let env = ProcessInfo.processInfo.environment
        return isatty(STDOUT_FILENO) != 0 && env["NO_COLOR"] == nil && env["TERM"] != "dumb"
    }()

    /// One of the terminal's 16 ANSI colours. The terminal theme picks the
    /// actual shade, so it stays legible on dark and light backgrounds alike;
    /// fixed RGB greys didn't (dark grey vanished on a dark background).
    struct Color {
        let code: Int
        var fg: String { "\(code)" }
    }

    static let accent = Color(code: 35)  // magenta
    static let green = Color(code: 32)
    static let yellow = Color(code: 33)
    static let red = Color(code: 31)
    static let blue = Color(code: 34)

    static func paint(_ s: String, _ codes: String...) -> String {
        guard enabled, !s.isEmpty else { return s }
        return "\u{1B}[\(codes.joined(separator: ";"))m\(s)\u{1B}[0m"
    }

    static func fg(_ s: String, _ c: Color) -> String { paint(s, c.fg) }
    static func bold(_ s: String) -> String { paint(s, "1") }
    /// Secondary text. Not greyed out: it stays in the terminal's normal
    /// text colour so it's always readable; hierarchy comes from colour and bold.
    static func dim(_ s: String) -> String { s }
    static func faint(_ s: String) -> String { s }
    static func strong(_ s: String, _ c: Color) -> String { paint(s, "1", c.fg) }

    static let ok = strong("✓", green)
    static let bad = strong("✗", red)
    static let warn = strong("!", yellow)

    /// "~/…" instead of the full home path.
    static func path(_ p: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return p.hasPrefix(home + "/") ? "~" + p.dropFirst(home.count) : p
    }

    /// Colours a session event by its leading marker (✓ ✗ ⚠) for display.
    /// The stored event text stays plain.
    static func event(_ message: String) -> String {
        for (marker, glyph, color) in [("✓ ", ok, green), ("✗ ", bad, red), ("⚠ ", warn, yellow)] where message.hasPrefix(marker) {
            let body = String(message.dropFirst(marker.count))
            return glyph + " " + highlightSubject(body, color)
        }
        return faint("·") + " " + dim(message)
    }

    /// Bolds "subject:" at the start of a message ("mic: …" → **mic** …).
    private static func highlightSubject(_ s: String, _ color: Color) -> String {
        guard let colon = s.range(of: ": ") else { return s }
        let subject = String(s[..<colon.lowerBound])
        guard subject.count <= 16 else { return s }
        return strong(subject, color) + " " + String(s[colon.upperBound...])
    }

    /// The text without escapes, for logs.
    static func plain(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
    }

    /// Pads by visible width (ignores escapes).
    static func pad(_ s: String, _ width: Int) -> String {
        s + String(repeating: " ", count: max(0, width - visibleWidth(s)))
    }

    static func visibleWidth(_ s: String) -> Int {
        var n = 0, inEscape = false
        for ch in s.unicodeScalars {
            if inEscape { if ch == "m" { inEscape = false }; continue }
            if ch == "\u{1B}" { inEscape = true; continue }
            n += 1
        }
        return n
    }

    /// A level meter from -70..0 dB with eighth-block resolution, coloured
    /// green → yellow → red along its length.
    static func meter(db: Double, width: Int) -> String {
        let level = ((db + 70) / 70).clamped(0, 1) * Double(width)
        let partials = ["", "▏", "▎", "▍", "▌", "▋", "▊", "▉"]
        var out = ""
        for i in 0..<width {
            let eighths = Int(((level - Double(i)) * 8).clamped(0, 8))
            guard eighths > 0 else { out += enabled ? faint("━") : "·"; continue }
            let glyph = eighths == 8 ? "█" : partials[eighths]
            let pos = Double(i) / Double(width)
            out += fg(glyph, pos < 0.65 ? green : pos < 0.85 ? yellow : red)
        }
        return out
    }
}

/// Raw keyboard input for interactive prompts. Restores the terminal on exit.
final class RawTerminal {
    private var original = termios()
    private let fd = STDIN_FILENO

    init?() {
        guard isatty(fd) != 0, tcgetattr(fd, &original) == 0 else { return nil }
        var raw = original
        raw.c_lflag &= ~tcflag_t(ECHO | ICANON)
        withUnsafeMutableBytes(of: &raw.c_cc) { cc in
            cc[Int(VMIN)] = 1
            cc[Int(VTIME)] = 0
        }
        tcsetattr(fd, TCSANOW, &raw)
        write("\u{1B}[?25l")
    }

    func restore() {
        tcsetattr(fd, TCSANOW, &original)
        write("\u{1B}[?25h")
    }

    enum Key { case up, down, enter, cancel, char(Character) }

    func readKey() -> Key {
        var byte: UInt8 = 0
        guard read(fd, &byte, 1) == 1 else { return .cancel }
        switch byte {
        case 3, 4: return .cancel                       // Ctrl-C, Ctrl-D
        case 10, 13: return .enter
        case 27:
            // ESC alone cancels; ESC [ A/B are arrows. Peek without blocking.
            var seq = [UInt8](repeating: 0, count: 2)
            let flags = fcntl(fd, F_GETFL)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
            usleep(20_000)
            let n = read(fd, &seq, 2)
            _ = fcntl(fd, F_SETFL, flags)
            guard n == 2, seq[0] == UInt8(ascii: "[") || seq[0] == UInt8(ascii: "O") else { return .cancel }
            if seq[1] == UInt8(ascii: "A") { return .up }
            if seq[1] == UInt8(ascii: "B") { return .down }
            return readKey()
        default: return .char(Character(UnicodeScalar(byte)))
        }
    }

    func write(_ s: String) {
        fputs(s, stdout)
        fflush(stdout)
    }
}
