import AppKit

enum ShortcutDisplayFormatter {
    static func displayString(keyCode: UInt16, modifiers: UInt) -> String {
        var parts: [String] = []
        let flags = NSEvent.ModifierFlags(rawValue: modifiers)
        if flags.contains(.control) { parts.append("\u{2303}") }
        if flags.contains(.option)  { parts.append("\u{2325}") }
        if flags.contains(.shift)   { parts.append("\u{21E7}") }
        if flags.contains(.command) { parts.append("\u{2318}") }
        parts.append(ScanCodeKeyMapper.keyName(for: keyCode) ?? "?")
        return parts.joined()
    }
}
