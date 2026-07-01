import XCTest
import AVFAudio
@testable import TitanPlayer

final class FormatDecoderTests: XCTestCase {
    func testFormatDecoderProtocol() {
        let decoder = MockFormatDecoder()

        XCTAssertTrue(decoder.canDecode(.pcm))
        XCTAssertFalse(decoder.canDecode(.dts))
    }
}

final class MockFormatDecoder: FormatDecoder {
    func canDecode(_ format: AudioFormatType) -> Bool {
        return format == .pcm
    }

    func decode(buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        return buffer
    }
}
