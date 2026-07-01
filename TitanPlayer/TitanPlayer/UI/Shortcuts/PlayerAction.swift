import AppKit

enum PlayerAction: String, CaseIterable, Codable {
    case togglePlayPause
    case seekForward10
    case seekBackward10
    case seekForward60
    case seekBackward60
    case stepFrameForward
    case stepFrameBackward
    case toggleMute
    case volumeUp
    case volumeDown
    case toggleFullscreen
    case toggleMiniPlayer
    case newLibraryWindow
    case openFile
    case setAspectRatioFit
    case setAspectRatioFill
    case setAspectRatioStretch
    case setAspectRatioAuto
    case toggleSubtitles
    case toggleHDR
    case increasePlaybackRate
    case decreasePlaybackRate
    case resetPlaybackRate
    case toggleWaveform
    case toggleVectorscope
    case toggleHistogram
    case toggleAudioMeters
}

struct KeyBinding: Equatable {
    let action: PlayerAction
    let key: String
    let modifiers: NSEvent.ModifierFlags

    init(action: PlayerAction, key: String, modifiers: NSEvent.ModifierFlags = []) {
        self.action = action
        self.key = key
        self.modifiers = modifiers
    }
}

extension KeyBinding: Codable {
    private enum CodingKeys: String, CodingKey {
        case action, key, modifiers
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        action = try c.decode(PlayerAction.self, forKey: .action)
        key = try c.decode(String.self, forKey: .key)
        let raw = try c.decode(UInt.self, forKey: .modifiers)
        modifiers = NSEvent.ModifierFlags(rawValue: raw)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(action, forKey: .action)
        try c.encode(key, forKey: .key)
        try c.encode(modifiers.rawValue, forKey: .modifiers)
    }
}
