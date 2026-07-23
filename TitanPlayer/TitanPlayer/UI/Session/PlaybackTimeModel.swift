import Foundation
import CoreMedia

/// Per-frame playback clock, isolated from `PlaybackSession` so that 60 Hz
/// time updates do not invalidate every view that observes the session.
///
/// Only views that genuinely need the live playback position (the seek bar,
/// the time read-out) read this model via `@Environment`. Everything else
/// observes `PlaybackSession` and therefore skips the per-frame churn.
///
/// `current`/`duration` are driven by the engine's 60 Hz display clock (the
/// AVPlayer periodic time observer, which reflects the real audio master
/// clock). Treat `current` as the display-link sample.
@MainActor
@Observable
final class PlaybackTimeModel {
    var current: CMTime = .zero
    var duration: CMTime = .zero

    var seconds: Double { CMTimeGetSeconds(current) }
    var durationSeconds: Double { CMTimeGetSeconds(duration) }

    var isReady: Bool { durationSeconds > 0 }
}
