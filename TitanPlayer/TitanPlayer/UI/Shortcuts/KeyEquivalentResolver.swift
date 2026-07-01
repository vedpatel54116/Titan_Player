import SwiftUI
import AppKit

enum KeyEquivalentResolver {
    struct Resolved: Equatable {
        let equivalent: KeyEquivalent
        let modifiers: EventModifiers
    }

    static func resolve(key: String, modifiers: NSEvent.ModifierFlags) -> Resolved? {
        guard let equivalent = keyEquivalent(for: key) else { return nil }
        return Resolved(equivalent: equivalent, modifiers: eventModifiers(from: modifiers))
    }

    private static func keyEquivalent(for key: String) -> KeyEquivalent? {
        switch key {
        case "space":           return .space
        case "return", "enter": return .return
        case "tab":             return .tab
        case "escape", "esc":   return .escape
        case "delete", "del":   return .delete
        case "uparrow":         return .upArrow
        case "downarrow":       return .downArrow
        case "leftarrow":       return .leftArrow
        case "rightarrow":      return .rightArrow
        case "home":            return .home
        case "end":             return .end
        case "pageup":          return .pageUp
        case "pagedown":        return .pageDown
        case "clear":           return .clear
        default:
            guard key.count == 1, let first = key.first else { return nil }
            return KeyEquivalent(first)
        }
    }

    private static func eventModifiers(from flags: NSEvent.ModifierFlags) -> EventModifiers {
        var m: EventModifiers = []
        if flags.contains(.command) { m.insert(.command) }
        if flags.contains(.shift)   { m.insert(.shift) }
        if flags.contains(.option)  { m.insert(.option) }
        if flags.contains(.control) { m.insert(.control) }
        return m
    }
}
