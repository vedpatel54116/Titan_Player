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
    let keyCode: UInt16
    let modifiers: NSEvent.ModifierFlags

    init(action: PlayerAction, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) {
        self.action = action
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

extension KeyBinding: Codable {
    private enum CodingKeys: String, CodingKey {
        case action, keyCode, modifiers
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        action = try c.decode(PlayerAction.self, forKey: .action)
        keyCode = try c.decode(UInt16.self, forKey: .keyCode)
        let raw = try c.decode(UInt.self, forKey: .modifiers)
        modifiers = NSEvent.ModifierFlags(rawValue: raw)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(action, forKey: .action)
        try c.encode(keyCode, forKey: .keyCode)
        try c.encode(modifiers.rawValue, forKey: .modifiers)
    }
}
