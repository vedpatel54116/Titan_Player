import AppKit
import Foundation
import os

@MainActor
final class KeyboardShortcutManager {
    static let defaultsKey = "titanplayer.keybindings"
    static var isRecordingShortcut = false

    private static let logger = Logger(subsystem: "com.titanplayer", category: "keyboard")

    private var bindings: [PlayerAction: KeyBinding] = [:]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        loadBindings()
    }

    func binding(for action: PlayerAction) -> KeyBinding? {
        bindings[action]
    }

    func setBinding(_ binding: KeyBinding, for action: PlayerAction) throws {
        if let conflict = bindings.first(where: {
            $0.key != action &&
            $0.value.keyCode == binding.keyCode &&
            $0.value.modifiers == binding.modifiers
        }) {
            throw NSError(domain: "KeyboardShortcutManager", code: 1,
                          userInfo: [NSLocalizedDescriptionKey:
                            "Key '\(ScanCodeKeyMapper.keyName(for: binding.keyCode) ?? "?")' already bound to \(conflict.key.rawValue)"])
        }
        bindings[action] = binding
        persist()
    }

    private func loadBindings() {
        if let data = defaults.data(forKey: Self.defaultsKey) {
            // Try new format first (scan-code based)
            if let decoded = try? JSONDecoder().decode([KeyBinding].self, from: data) {
                for b in decoded {
                    bindings[b.action] = b
                }
                for (action, b) in Self.defaultBindings where bindings[action] == nil {
                    bindings[action] = b
                }
                return
            }
            // Try old format (string-based) and migrate
            if let migrated = migrateOldBindings(data: data) {
                for b in migrated {
                    bindings[b.action] = b
                }
                persist()
                Self.logger.info("Migrated \(migrated.count) bindings from string-based to scan-code format")
                for (action, b) in Self.defaultBindings where bindings[action] == nil {
                    bindings[action] = b
                }
                return
            }
        }
        bindings = Self.defaultBindings
    }

    private func migrateOldBindings(data: Data) -> [KeyBinding]? {
        guard let oldBindings = try? JSONDecoder().decode(
            [OldKeyBinding].self, from: data
        ) else { return nil }

        return oldBindings.compactMap { old -> KeyBinding? in
            guard let keyCode = Self.stringToKeyCode[old.key] else { return nil }
            return KeyBinding(action: old.action, keyCode: keyCode,
                             modifiers: old.modifiers)
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(Array(bindings.values)) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    func resetToDefaults() {
        bindings = Self.defaultBindings
        persist()
    }

    // MARK: - Scan-Code Default Bindings

    static let defaultBindings: [PlayerAction: KeyBinding] = [
        .togglePlayPause:        .init(action: .togglePlayPause,        keyCode: 49),
        .seekBackward10:         .init(action: .seekBackward10,         keyCode: 123),
        .seekForward10:          .init(action: .seekForward10,          keyCode: 124),
        .seekBackward60:         .init(action: .seekBackward60,         keyCode: 123, modifiers: .command),
        .seekForward60:          .init(action: .seekForward60,          keyCode: 124, modifiers: .command),
        .stepFrameForward:       .init(action: .stepFrameForward,       keyCode: 47),
        .stepFrameBackward:      .init(action: .stepFrameBackward,      keyCode: 43),
        .volumeUp:               .init(action: .volumeUp,               keyCode: 126),
        .volumeDown:             .init(action: .volumeDown,             keyCode: 125),
        .toggleMute:             .init(action: .toggleMute,             keyCode: 46),
        .toggleFullscreen:       .init(action: .toggleFullscreen,       keyCode: 3,  modifiers: .command),
        .toggleMiniPlayer:       .init(action: .toggleMiniPlayer,       keyCode: 46, modifiers: .command),
        .newLibraryWindow:       .init(action: .newLibraryWindow,       keyCode: 38, modifiers: .command),
        .openFile:               .init(action: .openFile,               keyCode: 31, modifiers: .command),
        .setAspectRatioFit:      .init(action: .setAspectRatioFit,      keyCode: 18, modifiers: .option),
        .setAspectRatioFill:     .init(action: .setAspectRatioFill,     keyCode: 19, modifiers: .option),
        .setAspectRatioStretch:  .init(action: .setAspectRatioStretch,  keyCode: 20, modifiers: .option),
        .setAspectRatioAuto:     .init(action: .setAspectRatioAuto,     keyCode: 29, modifiers: .option),
        .toggleSubtitles:        .init(action: .toggleSubtitles,        keyCode: 9),
        .toggleHDR:              .init(action: .toggleHDR,              keyCode: 4),
        .increasePlaybackRate:   .init(action: .increasePlaybackRate,   keyCode: 30),
        .decreasePlaybackRate:   .init(action: .decreasePlaybackRate,   keyCode: 33),
        .resetPlaybackRate:      .init(action: .resetPlaybackRate,      keyCode: 42),
        .toggleWaveform:         .init(action: .toggleWaveform,         keyCode: 18),
        .toggleVectorscope:      .init(action: .toggleVectorscope,      keyCode: 19),
        .toggleHistogram:        .init(action: .toggleHistogram,        keyCode: 20),
        .toggleAudioMeters:      .init(action: .toggleAudioMeters,      keyCode: 21),
    ]

    // MARK: - Migration Support

    private struct OldKeyBinding: Decodable {
        let action: PlayerAction
        let key: String
        let modifiers: NSEvent.ModifierFlags

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            action = try c.decode(PlayerAction.self, forKey: .action)
            key = try c.decode(String.self, forKey: .key)
            let raw = try c.decode(UInt.self, forKey: .modifiers)
            modifiers = NSEvent.ModifierFlags(rawValue: raw)
        }

        enum CodingKeys: String, CodingKey {
            case action, key, modifiers
        }
    }

    static let stringToKeyCode: [String: UInt16] = [
        "space": 49, "return": 36, "enter": 36, "tab": 48,
        "escape": 53, "esc": 53, "delete": 51, "del": 51,
        "uparrow": 126, "downarrow": 125, "leftarrow": 123, "rightarrow": 124,
        "home": 115, "end": 119, "pageup": 116, "pagedown": 121, "clear": 71,
        "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5,
        "h": 4, "i": 34, "j": 38, "k": 40, "l": 37, "m": 46, "n": 45,
        "o": 31, "p": 35, "q": 12, "r": 15, "s": 1, "t": 17, "u": 32,
        "v": 9, "w": 13, "x": 7, "y": 16, "z": 6,
        "0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23,
        "6": 22, "7": 26, "8": 28, "9": 25,
        ".": 47, ",": 43, "[": 33, "]": 30, "\\": 42,
        "'": 39, ";": 41, "/": 44, "`": 50, "=": 24, "-": 27,
    ]
}
