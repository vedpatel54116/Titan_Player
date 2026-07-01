import XCTest
@testable import TitanPlayer

final class HRTFProcessorTests: XCTestCase {
    func testHRTFProcessorProcessesBuffer() throws {
        let processor = try HRTFProcessor()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
        buffer.frameLength = 1024

        let processed = try processor.process(buffer, at: SIMD3<Float>(1.0, 0.0, 0.0))

        XCTAssertNotNil(processed)
        XCTAssertEqual(processed.frameLength, 1024)
    }
}
