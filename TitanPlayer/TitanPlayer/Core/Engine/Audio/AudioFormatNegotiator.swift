import AVFAudio
import os

final class AudioFormatNegotiator {
    private var converterCache: [FormatPair: AVAudioConverter] = [:]
    private let logger = Logger(subsystem: "com.titanplayer.audio", category: "FormatNegotiator")

    struct FormatPair: Hashable {
        let sourceRate: Double
        let sourceChannels: Int
        let targetRate: Double
        let targetChannels: Int
    }

    func converter(from sourceFormat: AVAudioFormat, to targetFormat: AVAudioFormat) -> AVAudioConverter? {
        let key = FormatPair(
            sourceRate: sourceFormat.sampleRate,
            sourceChannels: Int(sourceFormat.channelCount),
            targetRate: targetFormat.sampleRate,
            targetChannels: Int(targetFormat.channelCount)
        )

        if let cached = converterCache[key] {
            return cached
        }

        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            logger.error("Cannot create converter from \(sourceFormat) to \(targetFormat)")
            return nil
        }

        // Downmix 5.1 → stereo using standard coefficients.
        if sourceFormat.channelCount == 6 && targetFormat.channelCount == 2 {
            converter.channelMap = [0, 1, -1, -1, -1, -1]
        }

        converterCache[key] = converter
        logger.info("Created format converter: \(sourceFormat.sampleRate)ch\(sourceFormat.channelCount) → \(targetFormat.sampleRate)ch\(targetFormat.channelCount)")
        return converter
    }

    func clear() {
        converterCache.removeAll()
    }
}
