import XCTest
import AVFAudio
@testable import TitanPlayer

final class CoreAudioBridgeTests: XCTestCase {
    func testCoreAudioBridgeStartsSuccessfully() throws {
        let bridge = try CoreAudioBridge()
        try bridge.start()
        XCTAssertTrue(bridge.isRunning)
        bridge.stop()
    }

    func testCoreAudioBridgeHandlesBuffer() throws {
        let bridge = try CoreAudioBridge()
        try bridge.start()

        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
        buffer.frameLength = 1024

        XCTAssertNoThrow(bridge.processBuffer(buffer))
        bridge.stop()
    }
}
