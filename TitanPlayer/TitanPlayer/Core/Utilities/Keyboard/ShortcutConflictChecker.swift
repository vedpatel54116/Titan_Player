import Foundation
import AppKit
import os

struct ShortcutConflict {
    let keyEquivalent: String
    let modifiers: NSEvent.ModifierFlags
    let systemMenuTitle: String

    var description: String {
        "\"\(systemMenuTitle)\" — \(modifiersDescription)\(keyEquivalent.uppercased())"
    }

    private var modifiersDescription: String {
        var parts: [String] = []
        if modifiers.contains(.command) { parts.append("⌘") }
        if modifiers.contains(.shift) { parts.append("⇧") }
        if modifiers.contains(.option) { parts.append("⌥") }
        if modifiers.contains(.control) { parts.append("⌃") }
        return parts.joined()
    }
}

final class ShortcutConflictChecker {
    static func findConflicts(keyEquivalent: String, modifiers: NSEvent.ModifierFlags) -> [ShortcutConflict] {
        var conflicts: [ShortcutConflict] = []

        guard let mainMenu = NSApp.mainMenu else { return [] }

        collectConflicts(in: mainMenu, keyEquivalent: keyEquivalent, modifiers: modifiers, conflicts: &conflicts)

        return conflicts
    }

    static func checkBeforeRegistering(keyEquivalent: String, modifiers: NSEvent.ModifierFlags, appShortcutName: String) -> Bool {
        let conflicts = findConflicts(keyEquivalent: keyEquivalent, modifiers: modifiers)

        if conflicts.isEmpty {
            return true
        }

        let conflictDescriptions = conflicts.map { $0.description }.joined(separator: ", ")
        os.Logger(subsystem: "com.titanplayer", category: "ShortcutConflict").info("'\(appShortcutName)' (\(keyEquivalent)) conflicts with: \(conflictDescriptions)")

        return false
    }

    private static func collectConflicts(in menu: NSMenu, keyEquivalent: String, modifiers: NSEvent.ModifierFlags, conflicts: inout [ShortcutConflict]) {
        for item in menu.items {
            if let submenu = item.submenu {
                collectConflicts(in: submenu, keyEquivalent: keyEquivalent, modifiers: modifiers, conflicts: &conflicts)
            }

            let itemKeyEq = item.keyEquivalent
            guard !itemKeyEq.isEmpty else { continue }
            guard itemKeyEq.caseInsensitiveCompare(keyEquivalent) == .orderedSame else { continue }

            let itemMods = item.keyEquivalentModifierMask
            if itemMods == modifiers {
                conflicts.append(ShortcutConflict(
                    keyEquivalent: itemKeyEq,
                    modifiers: itemMods,
                    systemMenuTitle: item.title
                ))
            }
        }
    }
}
