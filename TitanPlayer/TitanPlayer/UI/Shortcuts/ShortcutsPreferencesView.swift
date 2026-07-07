import SwiftUI
import AppKit

struct ShortcutsPreferencesView: View {
    @State private var manager: KeyboardShortcutManager?
    @State private var recordingAction: PlayerAction? = nil
    @State private var conflictError: String? = nil
    @State private var eventMonitor: Any? = nil

    private var resolvedManager: KeyboardShortcutManager {
        manager ?? KeyboardShortcutManager()
    }

    private let groups: [(String, [PlayerAction])] = [
        ("Playback", [
            .togglePlayPause, .seekBackward10, .seekForward10,
            .seekBackward60, .seekForward60,
            .stepFrameForward, .stepFrameBackward,
            .volumeUp, .volumeDown, .toggleMute,
            .toggleSubtitles, .toggleHDR,
            .increasePlaybackRate, .decreasePlaybackRate, .resetPlaybackRate
        ]),
        ("Window", [
            .openFile, .toggleFullscreen, .toggleMiniPlayer, .newLibraryWindow
        ]),
        ("Aspect", [
            .setAspectRatioFit, .setAspectRatioFill,
            .setAspectRatioStretch, .setAspectRatioAuto
        ]),
        ("Analysis", [
            .toggleWaveform, .toggleVectorscope,
            .toggleHistogram, .toggleAudioMeters
        ])
    ]

    var body: some View {
        Form {
            ForEach(groups, id: \.0) { group in
                Section(group.0) {
                    ForEach(group.1, id: \.self) { action in
                        shortcutRow(for: action)
                    }
                }
            }

            Section {
                Button("Reset to Defaults") {
                    resolvedManager.resetToDefaults()
                }
            }
        }
        .padding()
        .frame(width: 480, height: 520)
        .onAppear {
            if manager == nil {
                manager = KeyboardShortcutManager()
            }
        }
    }

    @ViewBuilder
    private func shortcutRow(for action: PlayerAction) -> some View {
        let binding = resolvedManager.binding(for: action)
        let display = binding.map {
            ShortcutDisplayFormatter.displayString(key: $0.key, modifiers: $0.modifiers)
        } ?? "None"
        let isRecording = recordingAction == action

        HStack {
            Text(action.displayName)
                .frame(width: 180, alignment: .leading)

            if isRecording {
                Text("Press a key...")
                    .foregroundStyle(.secondary)
                    .frame(width: 80, alignment: .leading)
            } else {
                Text(display)
                    .monospaced()
                    .frame(width: 80, alignment: .leading)
            }

            if let error = conflictError, isRecording {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer()

            if isRecording {
                Button("Cancel") { stopRecording() }
            } else {
                Button("Record") { startRecording(for: action) }
            }
        }
        .padding(.vertical, 2)
    }

    private func startRecording(for action: PlayerAction) {
        conflictError = nil
        recordingAction = action
        KeyboardShortcutManager.isRecordingShortcut = true

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                stopRecording()
                return event
            }

            let keyName = PhysicalKeyResolver.keyString(for: event)
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            let baseKeys: Set<String> = [
                "space", "return", "enter", "tab", "escape", "esc",
                "delete", "del", "uparrow", "downarrow", "leftarrow", "rightarrow",
                "home", "end", "pageup", "pagedown", "clear"
            ]
            let isSingleChar = keyName.count == 1
            guard isSingleChar || baseKeys.contains(keyName) else {
                return event
            }

            let candidate = KeyBinding(action: action, key: keyName, modifiers: mods)
            do {
                try resolvedManager.setBinding(candidate, for: action)
                stopRecording()
            } catch {
                conflictError = error.localizedDescription
            }

            return event
        }
    }

    private func stopRecording() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
        recordingAction = nil
        KeyboardShortcutManager.isRecordingShortcut = false
        conflictError = nil
    }
}

private extension PlayerAction {
    var displayName: String {
        switch self {
        case .togglePlayPause:        return "Play / Pause"
        case .seekBackward10:         return "Skip Back 10s"
        case .seekForward10:          return "Skip Forward 10s"
        case .seekBackward60:         return "Skip Back 60s"
        case .seekForward60:          return "Skip Forward 60s"
        case .stepFrameForward:       return "Step Frame Forward"
        case .stepFrameBackward:      return "Step Frame Backward"
        case .volumeUp:               return "Volume Up"
        case .volumeDown:             return "Volume Down"
        case .toggleMute:             return "Mute"
        case .toggleFullscreen:       return "Toggle Full Screen"
        case .toggleMiniPlayer:       return "Mini Player"
        case .newLibraryWindow:       return "New Library Window"
        case .openFile:               return "Open File"
        case .setAspectRatioFit:      return "Aspect: Fit"
        case .setAspectRatioFill:     return "Aspect: Fill"
        case .setAspectRatioStretch:  return "Aspect: Stretch"
        case .setAspectRatioAuto:     return "Aspect: Auto"
        case .toggleSubtitles:        return "Toggle Subtitles"
        case .toggleHDR:              return "Toggle HDR"
        case .increasePlaybackRate:   return "Increase Rate"
        case .decreasePlaybackRate:   return "Decrease Rate"
        case .resetPlaybackRate:      return "Reset Rate"
        case .toggleWaveform:         return "Waveform"
        case .toggleVectorscope:      return "Vectorscope"
        case .toggleHistogram:        return "Histogram"
        case .toggleAudioMeters:      return "Audio Meters"
        }
    }
}
