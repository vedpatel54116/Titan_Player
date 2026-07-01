import XCTest
@testable import TitanPlayer

final class FFmpegAudioDecoderTests: XCTestCase {
    func testFFmpegAudioDecoderCanDecodeAC3() {
        let decoder = FFmpegAudioDecoder()

        XCTAssertTrue(decoder.canDecode(.ac3))
        XCTAssertTrue(decoder.canDecode(.eac3))
        XCTAssertTrue(decoder.canDecode(.dts))
    }

    func testFFmpegAudioDecoderCannotDecodePCM() {
        let decoder = FFmpegAudioDecoder()

        XCTAssertFalse(decoder.canDecode(.pcm))
    }
}
