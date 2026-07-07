import Foundation

/// Provides the current audio playback time for synchronization.
///
/// - Note: Concrete conformers may be `@MainActor`-isolated (e.g. `PlaybackEngine`),
///   which makes reads from any thread safe. The protocol itself is intentionally
///   nonisolated so that background decode loops can snapshot the audio clock
///   without hopping to MainActor.
protocol SynchronizationProvider: AnyObject {
    /// Returns the current audio playback time in seconds.
    var audioCurrentTime: TimeInterval { get }
}