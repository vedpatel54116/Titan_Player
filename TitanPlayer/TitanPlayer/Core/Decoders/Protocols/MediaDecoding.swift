import Foundation

protocol MediaDecoding {
    func configure(for track: VideoTrackInfo) throws
    func decode(_ packet: MediaPacket) async throws -> MediaFrame
    func flush()
    func reset()
}

extension MediaDecoding {
    func flush() {}
    func reset() {}
}
