import AppKit

enum ShortcutDisplayFormatter {
    static func displayString(key: String, modifiers: NSEvent.ModifierFlags) -> String {
        var parts: [String] = []

        if modifiers.contains(.control) { parts.append("\u{2303}") }
        if modifiers.contains(.option)  { parts.append("\u{2325}") }
        if modifiers.contains(.shift)   { parts.append("\u{21E7}") }
        if modifiers.contains(.command) { parts.append("\u{2318}") }

        parts.append(displayKey(key))

        return parts.joined()
    }

    private static func displayKey(_ key: String) -> String {
        switch key {
        case "space":     return "Space"
        case "return", "enter": return "\u{21A9}"
        case "tab":       return "\u{21E5}"
        case "escape", "esc": return "\u{238B}"
        case "delete", "del": return "\u{232B}"
        case "uparrow":   return "\u{2191}"
        case "downarrow": return "\u{2193}"
        case "leftarrow": return "\u{2190}"
        case "rightarrow": return "\u{2192}"
        case "home":      return "\u{2196}"
        case "end":       return "\u{2198}"
        case "pageup":    return "\u{21DE}"
        case "pagedown":  return "\u{21DF}"
        case "clear":     return "\u{2327}"
        default:
            if key.count == 1 { return key.uppercased() }
            return key
        }
    }
}
