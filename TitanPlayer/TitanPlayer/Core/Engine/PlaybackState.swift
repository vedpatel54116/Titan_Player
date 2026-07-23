import Foundation

/// Single source of truth for the player's playback state machine.
///
/// Every visible player state flows through this one enum. UI, engine, and
/// streaming layers all read from — and transition through — ``PlaybackState``
/// so that state is never duplicated or allowed to drift across subsystems.
///
/// The states form a small, well-defined machine:
/// - `.idle` is the resting start/end state.
/// - `.loading` covers opening/preparing a source URL.
/// - `.ready` means the asset is prepared but not yet advancing.
/// - `.playing` / `.paused` are the steady interactive states.
/// - `.buffering` and `.seeking` are transient in-flight states.
/// - `.ended` is the terminal success state.
/// - `.error` is the terminal failure state.
enum PlaybackState: Sendable, Equatable, Codable {
    /// Nothing loaded; the player is at rest.
    case idle
    /// A source URL has been supplied and is being opened/prepared.
    case loading(URL)
    /// The asset is prepared and ready to play (but not yet advancing).
    case ready
    /// Actively producing output.
    case playing
    /// Playback is paused.
    case paused
    /// Stalled while filling the buffer; `progress` is `0...1`.
    case buffering(progress: Double)
    /// A seek is in flight to the given target time, in seconds.
    case seeking(to: Double)
    /// Playback reached the end of the item.
    case ended
    /// Playback failed with the associated error.
    case error(PlaybackError)

    // MARK: - Derived flags

    /// Whether the player is currently producing output.
    ///
    /// `true` only for `.playing`; every other state reports `false`.
    var isPlaying: Bool {
        if case .playing = self { return true }
        return false
    }

    /// Whether the current item supports seeking right now.
    ///
    /// Seekable states are the steady/interactive ones — `.ready`,
    /// `.playing`, `.paused`, `.buffering`, and `.seeking`. Terminal or
    /// not-yet-prepared states (`.idle`, `.loading`, `.ended`, `.error`) are
    /// not seekable.
    var isSeekable: Bool {
        switch self {
        case .ready, .playing, .paused, .buffering, .seeking:
            return true
        case .idle, .loading, .ended, .error:
            return false
        }
    }

    // MARK: - Description

    /// Human-readable description of the state, suitable for logging and UI.
    var description: String {
        switch self {
        case .idle:
            return "idle"
        case .loading(let url):
            return "loading(\(url.lastPathComponent))"
        case .ready:
            return "ready"
        case .playing:
            return "playing"
        case .paused:
            return "paused"
        case .buffering(let progress):
            return "buffering(\(String(format: "%.2f", progress)))"
        case .seeking(let time):
            return "seeking(\(String(format: "%.2f", time)))"
        case .ended:
            return "ended"
        case .error(let error):
            return "error(\(error.localizedDescription))"
        }
    }
}

extension PlaybackState: CustomStringConvertible {}

/// Deprecated alias retained for backward compatibility while call sites
/// migrate to ``PlaybackState`` as the single source of truth.
///
/// New code should reference ``PlaybackState`` directly.
@available(*, deprecated, renamed: "PlaybackState",
           message: "Use PlaybackState as the single source of truth for playback state.")
typealias PlayState = PlaybackState
