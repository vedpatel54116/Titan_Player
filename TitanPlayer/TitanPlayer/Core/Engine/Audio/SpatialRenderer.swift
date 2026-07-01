import AVFAudio
import simd

final class SpatialRenderer {
    private let hrtfProcessor: HRTFProcessor
    private let roomSimulation: RoomSimulation

    init() throws {
        hrtfProcessor = try HRTFProcessor()
        roomSimulation = RoomSimulation()
    }

    func process(_ buffer: AVAudioPCMBuffer, for object: AudioObject) throws -> AVAudioPCMBuffer {
        var processed = try hrtfProcessor.process(buffer, at: object.position)
        processed = try roomSimulation.applyReverb(processed, amount: 0.3)

        if let channelData = processed.floatChannelData {
            for channel in 0..<Int(processed.format.channelCount) {
                for i in 0..<Int(processed.frameLength) {
                    channelData[channel][i] *= object.gain
                }
            }
        }

        return processed
    }
}
