import Foundation

protocol MediaDecoding {
    /// Tap fired with each decoded `AudioFrame`. Useful for analysis tools
    /// (loudness metering, true-peak detection) that want access to decoded
    /// audio independent of any downstream playback path.
    var audioTap: ((AudioFrame) -> Void)? { get set }

    func configure(for track: VideoTrackInfo) throws
    func decode(_ packet: MediaPacket) async throws -> MediaFrame
    func flush()
    func reset()
}

extension MediaDecoding {
    func flush() {}
    func reset() {}
}
