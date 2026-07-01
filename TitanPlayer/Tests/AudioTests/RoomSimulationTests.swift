import XCTest
import AVFAudio
@testable import TitanPlayer

final class RoomSimulationTests: XCTestCase {
    func testRoomSimulationAppliesReverb() throws {
        let simulation = RoomSimulation()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024)!
        buffer.frameLength = 1024

        let processed = try simulation.applyReverb(buffer, amount: 0.5)

        XCTAssertNotNil(processed)
        XCTAssertEqual(processed.frameLength, 1024)
    }
}
