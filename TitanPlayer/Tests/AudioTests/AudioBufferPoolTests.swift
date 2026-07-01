import XCTest
@testable import TitanPlayer

final class AudioBufferPoolTests: XCTestCase {
    func testBufferPoolReturnsBufferWithCorrectFormat() {
        let pool = AudioBufferPool()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!

        let buffer = pool.dequeueBuffer(for: format, frameCount: 1024)

        XCTAssertNotNil(buffer)
        XCTAssertEqual(buffer.format.sampleRate, 48000)
        XCTAssertEqual(buffer.format.channelCount, 2)
        XCTAssertEqual(buffer.frameLength, 1024)
    }

    func testBufferPoolReusesBuffers() {
        let pool = AudioBufferPool()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!

        let buffer1 = pool.dequeueBuffer(for: format, frameCount: 1024)
        pool.enqueueBuffer(buffer1)
        let buffer2 = pool.dequeueBuffer(for: format, frameCount: 1024)

        XCTAssertTrue(buffer1 === buffer2)
    }
}
