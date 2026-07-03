import AVFAudio
import simd
import Accelerate

final class HRTFProcessor {
    private let headRadius: Float = 0.0875
    private let speedOfSound: Float = 343.0
    private var sampleRate: Double = 48000
    private var leftState: [Double] = [0, 0]
    private var rightState: [Double] = [0, 0]

    init() throws {
    }

    func process(_ buffer: AVAudioPCMBuffer, at position: SIMD3<Float>) throws -> AVAudioPCMBuffer {
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            throw HRTFProcessorError.bufferCreationFailed
        }

        outputBuffer.frameLength = buffer.frameLength
        sampleRate = buffer.format.sampleRate

        let azimuth = atan2(position.x, position.z)
        let distance = max(sqrt(position.x * position.x + position.y * position.y + position.z * position.z), 0.1)

        let itdSamples = computeITD(azimuth: azimuth) * sampleRate / 1000.0
        let headShadowCutoff = computeHeadShadowCutoff(azimuth: azimuth)

        let channelCount = min(Int(buffer.format.channelCount), 2)
        let frameCount = Int(buffer.frameLength)

        for channel in 0..<channelCount {
            guard let inputData = buffer.floatChannelData?[channel],
                  let outputData = outputBuffer.floatChannelData?[channel] else {
                continue
            }

            var delaySamples: Double
            var cutoff: Float
            if channel == 0 {
                delaySamples = itdSamples * 0.5
                cutoff = headShadowCutoff
            } else {
                delaySamples = -itdSamples * 0.5
                cutoff = headShadowCutoff * 1.5
            }

            for i in 0..<frameCount {
                var sample = inputData[i]

                let delayWhole = Int(floor(delaySamples))
                let delayFrac = Float(delaySamples - Double(delayWhole))
                let srcIndex = i - delayWhole
                if srcIndex >= 1 && srcIndex < frameCount {
                    sample = inputData[srcIndex] * (1 - delayFrac) + inputData[srcIndex - 1] * delayFrac
                } else if srcIndex >= 0 && srcIndex < frameCount {
                    sample = inputData[srcIndex]
                } else {
                    sample = 0
                }

                let rc: Float = 1.0 / (2.0 * .pi * cutoff)
                let alpha: Float = Float(1.0 / (sampleRate * Double(rc) + 1.0))
                if channel == 0 {
                    leftState[0] = Double(alpha) * Double(sample) + (1.0 - Double(alpha)) * leftState[0]
                    outputData[i] = Float(leftState[0])
                } else {
                    rightState[0] = Double(alpha) * Double(sample) + (1.0 - Double(alpha)) * rightState[0]
                    outputData[i] = Float(rightState[0])
                }
            }
        }

        let distanceAttenuation = min(1.0 / (distance * distance), 1.0)
        var gain = distanceAttenuation * 0.8
        for channel in 0..<channelCount {
            guard let outputData = outputBuffer.floatChannelData?[channel] else { continue }
            vDSP_vsmul(outputData, 1, &gain, outputData, 1, vDSP_Length(frameCount))
        }

        return outputBuffer
    }

    private func computeITD(azimuth: Float) -> Double {
        let theta = abs(azimuth)
        let itd = (headRadius / speedOfSound) * (theta + sin(theta))
        return Double(itd * 1000)
    }

    private func computeHeadShadowCutoff(azimuth: Float) -> Float {
        let absAzimuth = abs(azimuth)
        let normalizedAzimuth = min(absAzimuth / (.pi / 2), 1.0)
        return 4000.0 - normalizedAzimuth * 3200.0
    }

    func reset() {
        leftState = [0, 0]
        rightState = [0, 0]
    }
}

enum HRTFProcessorError: Error {
    case bufferCreationFailed
    case hrtfDataNotFound
}
