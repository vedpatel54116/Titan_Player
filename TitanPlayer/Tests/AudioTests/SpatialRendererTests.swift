import XCTest
import AVFAudio
@testable import TitanPlayer

final class SpatialRendererTests: XCTestCase {
    func testSpatialRendererProcessesAudio() throws {
        let renderer = try SpatialRenderer()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
        buffer.frameLength = 1024

        let object = AudioObject(
            id: UUID(),
            position: SIMD3<Float>(1.0, 0.0, 0.0),
            gain: 1.0,
            spread: 0.5,
            source: .object(1)
        )

        let processed = try renderer.process(buffer, for: object)

        XCTAssertNotNil(processed)
        XCTAssertEqual(processed.frameLength, 1024)
    }
}
