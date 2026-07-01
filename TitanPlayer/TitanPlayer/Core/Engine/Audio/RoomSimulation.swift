import AVFAudio

final class RoomSimulation {
    private var reverbBuffer: [Float] = []
    private let reverbLength: Int = 4800

    init() {
        generateReverbImpulse()
    }

    private func generateReverbImpulse() {
        reverbBuffer = (0..<reverbLength).map { i in
            Float(exp(-Double(i) / Double(reverbLength) * 3.0))
        }
    }

    func applyReverb(_ buffer: AVAudioPCMBuffer, amount: Float) throws -> AVAudioPCMBuffer {
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            throw RoomSimulationError.bufferCreationFailed
        }

        outputBuffer.frameLength = buffer.frameLength

        if let inputChannel = buffer.floatChannelData?[0],
           let outputChannel = outputBuffer.floatChannelData?[0] {
            for i in 0..<Int(buffer.frameLength) {
                var sample = inputChannel[i]
                for j in 0..<min(reverbLength, i + 1) {
                    sample += inputChannel[i - j] * reverbBuffer[j] * amount
                }
                outputChannel[i] = sample
            }
        }

        return outputBuffer
    }
}

enum RoomSimulationError: Error {
    case bufferCreationFailed
}
