import CoreMedia

/// A resolved subtitle presentation for a given time. Either styled text
/// events (SRT/WebVTT) or a pre-rendered bitmap (ASS/SSA via libass).
enum SubtitleLayer: Sendable, Equatable {
    case text([SubtitleEvent])
    case bitmap(SubtitleBitmap)
}

/// A single subtitle cue spanning `[start, end]`, rendered as a `SubtitleLayer`.
struct SubtitleCue: Equatable {
    let start: CMTime
    let end: CMTime
    let layer: SubtitleLayer
}

/// Drives subtitle rendering at a playback time and returns the active layer.
@MainActor
class SubtitleEngine: ObservableObject {
    /// Returns the subtitle layer active at `time`, or `nil` when no subtitle
    /// is visible.
    func update(time: CMTime) -> SubtitleLayer? {
        nil
    }
}
