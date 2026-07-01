import XCTest
import AVFAudio
@testable import TitanPlayer

@MainActor
final class AudioEngineTests: XCTestCase {
    func testAudioEngineStartsSuccessfully() throws {
        let engine = try AudioEngine()
        try engine.startEngine()
        XCTAssertTrue(engine.isRunning)
        engine.stop()
    }

    func testAudioEngineProcessesBuffer() throws {
        let engine = try AudioEngine()
        try engine.startEngine()

        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
        buffer.frameLength = 1024

        engine.processAudioBuffer(buffer)
        engine.stop()
    }
}
