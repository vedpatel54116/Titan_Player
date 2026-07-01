import AppKit
import Foundation

@MainActor
final class KeyboardShortcutManager {
    static let defaultsKey = "titanplayer.keybindings"

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
        let resolved = KeyBinding(action: action, key: binding.key, modifiers: binding.modifiers)
        if let conflict = bindings.first(where: {
            $0.key != action &&
            $0.value.key == resolved.key &&
            $0.value.modifiers == resolved.modifiers
        }) {
            throw NSError(domain: "KeyboardShortcutManager", code: 1,
                          userInfo: [NSLocalizedDescriptionKey:
                            "Key '\(resolved.key)' already bound to \(conflict.key.rawValue)"])
        }
        bindings[action] = resolved
        persist()
    }

    private func loadBindings() {
        if let data = defaults.data(forKey: Self.defaultsKey) {
            do {
                let decoded = try JSONDecoder().decode([KeyBinding].self, from: data)
                for b in decoded {
                    bindings[b.action] = b
                }
                for (action, b) in Self.defaultBindings where bindings[action] == nil {
                    bindings[action] = b
                }
                return
            } catch {
            }
        }
        bindings = Self.defaultBindings
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(Array(bindings.values)) {
            defaults.set(data, forKey: Self.defaultsKey)
        }
    }

    static let defaultBindings: [PlayerAction: KeyBinding] = [
        .togglePlayPause:        .init(action: .togglePlayPause,        key: "space"),
        .seekBackward10:         .init(action: .seekBackward10,         key: "leftarrow"),
        .seekForward10:          .init(action: .seekForward10,          key: "rightarrow"),
        .seekBackward60:         .init(action: .seekBackward60,         key: "leftarrow",  modifiers: .command),
        .seekForward60:          .init(action: .seekForward60,          key: "rightarrow", modifiers: .command),
        .stepFrameForward:       .init(action: .stepFrameForward,       key: "."),
        .stepFrameBackward:      .init(action: .stepFrameBackward,      key: ","),
        .volumeUp:               .init(action: .volumeUp,               key: "uparrow"),
        .volumeDown:             .init(action: .volumeDown,             key: "downarrow"),
        .toggleMute:             .init(action: .toggleMute,             key: "m"),
        .toggleFullscreen:       .init(action: .toggleFullscreen,       key: "f",          modifiers: .command),
        .toggleMiniPlayer:       .init(action: .toggleMiniPlayer,       key: "m",          modifiers: .command),
        .newLibraryWindow:       .init(action: .newLibraryWindow,       key: "l",          modifiers: .command),
        .openFile:               .init(action: .openFile,               key: "o",          modifiers: .command),
        .setAspectRatioFit:      .init(action: .setAspectRatioFit,      key: "1",          modifiers: .option),
        .setAspectRatioFill:     .init(action: .setAspectRatioFill,     key: "2",          modifiers: .option),
        .setAspectRatioStretch:  .init(action: .setAspectRatioStretch,  key: "3",          modifiers: .option),
        .setAspectRatioAuto:     .init(action: .setAspectRatioAuto,     key: "0",          modifiers: .option),
        .toggleSubtitles:        .init(action: .toggleSubtitles,        key: "v"),
        .toggleHDR:              .init(action: .toggleHDR,              key: "h"),
        .increasePlaybackRate:   .init(action: .increasePlaybackRate,   key: "]"),
        .decreasePlaybackRate:   .init(action: .decreasePlaybackRate,   key: "["),
        .resetPlaybackRate:      .init(action: .resetPlaybackRate,      key: "\\"),
        .toggleWaveform:        .init(action: .toggleWaveform,        key: "1"),
        .toggleVectorscope:     .init(action: .toggleVectorscope,     key: "2"),
        .toggleHistogram:       .init(action: .toggleHistogram,       key: "3"),
        .toggleAudioMeters:     .init(action: .toggleAudioMeters,     key: "4"),
    ]
}
