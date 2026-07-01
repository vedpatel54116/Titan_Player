import Foundation

struct AudioMetadata {
    let title: String?
    let artist: String?
    let album: String?
    let duration: TimeInterval
    let sampleRate: Double
    let channelCount: Int
    let bitrate: Int
    let format: AudioFormatType
    let channelLayout: ChannelLayout?

    init(
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        duration: TimeInterval = 0,
        sampleRate: Double = 44100,
        channelCount: Int = 2,
        bitrate: Int = 0,
        format: AudioFormatType = .unknown,
        channelLayout: ChannelLayout? = nil
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.bitrate = bitrate
        self.format = format
        self.channelLayout = channelLayout
    }
}
