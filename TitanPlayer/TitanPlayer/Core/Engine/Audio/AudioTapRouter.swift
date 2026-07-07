import AVFAudio

/// Routes decoded PCM frames to the loudness meter and optional spatial
/// audio engine. Extracted from `PlaybackSession` to isolate audio-tap
/// wiring from UI session logic.
@MainActor
final class AudioTapRouter {
    private let meter: LFSAudioMeter
    private let engineProvider: () -> AudioEngine?

    init(meter: LFSAudioMeter, engineProvider: @escaping () -> AudioEngine?) {
        self.meter = meter
        self.engineProvider = engineProvider
    }

    /// The closure assigned to `PlaybackEngine.audioTap`.
    var tapClosure: AudioTap {
        { [weak self] frame in
            guard let self else { return }
            Task { @MainActor in
                self.meter.consume(frame: frame)
                if let spatialEngine = self.engineProvider(),
                   spatialEngine.isRunning {
                    let buf = Self.makePCMBuffer(from: frame)
                    spatialEngine.processAudioBuffer(buf)
                }
            }
        }
    }

    /// Convert a decoded `AudioFrame` into an `AVAudioPCMBuffer` suitable
    /// for feeding into `AudioEngine.processAudioBuffer(_:)`.
    nonisolated static func makePCMBuffer(from frame: AudioFrame) -> AVAudioPCMBuffer {
        let ch  = frame.format.channels
        let rate = frame.format.sampleRate
        let format = AVAudioFormat(standardFormatWithSampleRate: Double(rate),
                                   channels: AVAudioChannelCount(ch))!
        let total = frame.buffer.count
        let frames = total / ch
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(frames))!
        buf.frameLength = UInt32(frames)
        let src = frame.buffer
        if frame.format.isInterleaved {
            for c in 0..<ch {
                let dst = buf.floatChannelData![c]
                for i in 0..<frames { dst[i] = src[i * ch + c] }
            }
        } else {
            for c in 0..<ch {
                let dst = buf.floatChannelData![c]
                for i in 0..<frames { dst[i] = src[c * frames + i] }
            }
        }
        return buf
    }
}
