import AVFAudio

final class FFmpegAudioDecoder: FormatDecoder {
    func canDecode(_ format: AudioFormatType) -> Bool {
        switch format {
        case .ac3, .eac3, .dts:
            return true
        default:
            return false
        }
    }

    func decode(buffer: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        return buffer
    }
}
