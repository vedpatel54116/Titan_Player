import XCTest
import AVFAudio
@testable import TitanPlayer

@MainActor
final class AudioTapTests: XCTestCase {

    private func makeEngine() -> PlaybackEngine {
        PlaybackEngine(videoRenderer: MockFrameRenderer())
    }

    private func testFileURL() throws -> URL {
        guard let url = Bundle(for: type(of: self)).url(forResource: "test", withExtension: "mp4") else {
            throw XCTSkip("Fixtures/test.mp4 missing from test bundle")
        }
        return url
    }

    func testAudioTapSourceIsNilBeforeLoad() {
        let engine = makeEngine()
        XCTAssertNil(engine.audioTapSource)
    }

    func testAudioTapSourceReturnsDecoderAfterLoad() async throws {
        let engine = makeEngine()
        let url = try testFileURL()
        try await engine.load(url: url)
        let decoder = engine.audioTapSource
        XCTAssertNotNil(decoder, "audioTapSource should return a decoder after load(url:)")
        XCTAssertTrue(decoder is MediaDecoding, "audioTapSource should conform to MediaDecoding")
    }

    func testAudioTapSourceIsNilAfterStop() async throws {
        let engine = makeEngine()
        let url = try testFileURL()
        try await engine.load(url: url)
        XCTAssertNotNil(engine.audioTapSource)
        engine.stop()
        XCTAssertNil(engine.audioTapSource)
    }
}
