import Foundation

/// Provides read-only access to the audio tap closure for decoding-layer
/// consumers. `MediaPipeline` conforms so that `PlaybackSession` can wire
/// the meter (and optionally the spatial audio engine) without reflection.
@MainActor
protocol AudioTapProvider {
    var audioTap: AudioTap? { get }
}
