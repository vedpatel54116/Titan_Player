import XCTest
import AVFAudio
@testable import TitanPlayer

final class AudioMetadataTests: XCTestCase {
    func testMetadataParsing() {
        let metadata = AudioMetadata(
            title: "Test Track",
            artist: "Test Artist",
            album: "Test Album",
            duration: 180.0,
            sampleRate: 48000,
            channelCount: 2,
            bitrate: 320000
        )

        XCTAssertEqual(metadata.title, "Test Track")
        XCTAssertEqual(metadata.sampleRate, 48000)
        XCTAssertEqual(metadata.channelCount, 2)
    }
}
