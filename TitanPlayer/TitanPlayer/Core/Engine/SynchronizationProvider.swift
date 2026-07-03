import Foundation

/// Provides the current audio playback time for synchronization.
@MainActor
protocol SynchronizationProvider: AnyObject {
    /// Returns the current audio playback time in seconds.
    var audioCurrentTime: TimeInterval { get }
}